"""세션 단위 5-fold 교차검증 — 데이터 누수 없는 성능 측정.

배경 (2026-08-21 발견):
  843장 중 789장(93.6%)이 연속 촬영 그룹에 속하고, `_saved` 파일의 40.4%는
  픽셀차 10 미만의 근사 중복이다(연사 프레임). 무작위 분할은 `_001`로 학습하고
  `_002`로 평가하게 만들어 성능을 부풀린다.
  - 무작위 5-fold: right 93.5%
  - 기존 단일 분할: right 75.0%
  두 값이 이항검정상 양립 불가(P=0.017)였고, 원인이 이 누수였다.

이 스크립트는 **같은 촬영 세션의 사진은 통째로 같은 fold**에 넣어 누수를 없앤다.

세션 정의:
  EXIF DateTimeOriginal 기준(843장 전부 보유), 시간순 정렬 후 **간격 60초 초과**면
  새 세션. -> 147개 세션, 최대 세션 43장.
  300초/900초도 검토했으나 최대 세션이 181장/199장(전체의 21~24%)이 되어 fold
  균형이 무너지므로 기각했다.
  클래스별로 나누지 않고 **세션 전체를 한 덩어리로** 다룬다. 같은 횡단보도를
  front/left/right로 찍은 사진들이 fold를 넘나들면 그 역시 누수이기 때문이다.

누수 없음 보증:
  분할 직후 assert로 (1) 한 세션이 두 fold에 걸치지 않는지 (2) 근사 중복
  클러스터가 두 fold에 걸치지 않는지를 강제 검사한다. 위반 시 즉시 중단한다.

평가 집계:
  근사 중복(픽셀차 < 10)은 클러스터당 1장만 세는 값을 **주 지표**로 보고한다.
  같은 사진 4장을 4표본으로 세면 표본 수가 부풀려지기 때문이다. 전체 집계도 함께 낸다.

원본(train_model.py)과의 차이 — 해석 시 감안할 것:
  fold당 train 70% / val 10% / test 20% (원본은 80/10/10).
  학습 데이터가 적으므로 여기 수치는 배포 모델보다 낮게 나오는 보수적 추정일 수 있다.
그 외 transform·모델·샘플러·클래스가중치·에폭/LR/스케줄러는 원본과 동일하다.
"""
import json
import math
import os
import random
from collections import defaultdict
from datetime import datetime
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
from PIL import Image, ImageOps
import PIL.ExifTags as ExifTags
from torch.utils.data import DataLoader, Dataset, WeightedRandomSampler
from torchvision import transforms
from torchvision.models import MobileNet_V3_Small_Weights, mobilenet_v3_small

SEED = 42
random.seed(SEED)
np.random.seed(SEED)
torch.manual_seed(SEED)

REPO = Path(__file__).resolve().parent.parent
DATA_DIR = REPO / "image"
OUT_DIR = REPO / "train" / "groupkfold_out"

# ImageFolder 알파벳 순서와 동일해야 한다 (classifier.dart:28과 같은 순서).
CLASSES = ["front", "left", "none", "right"]

IMG_SIZE = 224
BATCH_SIZE = 32
EPOCHS_FROZEN = 10
EPOCHS_FINETUNE = 10
LR_FROZEN = 1e-3
LR_FINETUNE = 1e-4
N_FOLDS = 5

SESSION_GAP_SEC = 60
DUP_PIXEL_THR = 10.0

# 앱 실제 임계값 — classifier.dart:33,38,39 / eval_model.py:50-52와 동일.
FRONT_T, DEV_T, NONE_T = 0.5, 0.55, 0.50

TRAIN_TF = transforms.Compose([
    transforms.Resize((IMG_SIZE, IMG_SIZE)),
    transforms.RandomHorizontalFlip(),
    transforms.RandomRotation(15),
    transforms.ColorJitter(brightness=0.3, contrast=0.3, saturation=0.2, hue=0.05),
    transforms.ToTensor(),
    transforms.Normalize([0.485, 0.456, 0.406], [0.229, 0.224, 0.225]),
])
EVAL_TF = transforms.Compose([
    transforms.Resize((IMG_SIZE, IMG_SIZE)),
    transforms.ToTensor(),
    transforms.Normalize([0.485, 0.456, 0.406], [0.229, 0.224, 0.225]),
])


class ListDataset(Dataset):
    def __init__(self, items, tf):
        self.items = items
        self.tf = tf

    def __len__(self):
        return len(self.items)

    def __getitem__(self, i):
        path, label = self.items[i]
        return self.tf(Image.open(path).convert("RGB")), label


def wilson(k, n, z=1.96):
    if n == 0:
        return (float("nan"), float("nan"))
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0.0, c - h), min(1.0, c + h))


def load_images():
    """EXIF 촬영시각과 함께 전체 이미지 목록을 만든다."""
    out = []
    for ci, cls in enumerate(CLASSES):
        for f in sorted(os.listdir(DATA_DIR / cls)):
            if not f.lower().endswith((".jpg", ".jpeg", ".png")):
                continue
            p = DATA_DIR / cls / f
            ex = Image.open(p)._getexif() or {}
            dt = None
            for k, v in ex.items():
                if ExifTags.TAGS.get(k) == "DateTimeOriginal":
                    dt = datetime.strptime(v, "%Y:%m:%d %H:%M:%S")
            if dt is None:
                raise RuntimeError(f"EXIF 촬영시각 없음: {p} — 세션 분할 불가")
            out.append({"path": str(p), "cls": cls, "ci": ci, "file": f, "dt": dt})
    return out


def assign_sessions(items):
    items.sort(key=lambda r: r["dt"])
    sid = 0
    prev = None
    for r in items:
        if prev is not None and (r["dt"] - prev).total_seconds() > SESSION_GAP_SEC:
            sid += 1
        r["session"] = sid
        prev = r["dt"]
    return sid + 1


def dup_clusters(items):
    """세션 내에서 픽셀차 < DUP_PIXEL_THR 인 이미지들을 한 클러스터로 묶는다."""
    sig = {}
    for r in items:
        im = ImageOps.exif_transpose(Image.open(r["path"])).convert("L").resize((64, 64))
        sig[r["file"]] = np.asarray(im, dtype=np.float32)

    by_sess = defaultdict(list)
    for r in items:
        by_sess[r["session"]].append(r)

    parent = {r["file"]: r["file"] for r in items}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    for _, rs in by_sess.items():
        for i in range(len(rs)):
            for j in range(i + 1, len(rs)):
                a, b = rs[i]["file"], rs[j]["file"]
                if float(np.abs(sig[a] - sig[b]).mean()) < DUP_PIXEL_THR:
                    union(a, b)
    for r in items:
        r["dupc"] = find(r["file"])
    return len({r["dupc"] for r in items})


def split_folds(items, n_sessions):
    """세션을 fold에 배정. 큰 세션부터 '가장 비어 있는 fold'에 넣는 그리디 균형 배정."""
    by_sess = defaultdict(list)
    for r in items:
        by_sess[r["session"]].append(r)

    load = [defaultdict(int) for _ in range(N_FOLDS)]
    fold_of = {}
    for s in sorted(by_sess, key=lambda s: -len(by_sess[s])):
        counts = Counter_cls(by_sess[s])
        # 이 세션이 가진 클래스들에 대해 현재 가장 부족한 fold를 고른다
        best = min(range(N_FOLDS), key=lambda k: (sum(load[k][c] for c in counts), sum(load[k].values())))
        fold_of[s] = best
        for c, n in counts.items():
            load[best][c] += n

    for r in items:
        r["fold"] = fold_of[r["session"]]

    # ── 누수 없음 하드 검사 ──────────────────────────────────────────
    sess_folds = defaultdict(set)
    dup_folds = defaultdict(set)
    for r in items:
        sess_folds[r["session"]].add(r["fold"])
        dup_folds[r["dupc"]].add(r["fold"])
    bad_s = {s: f for s, f in sess_folds.items() if len(f) > 1}
    bad_d = {d: f for d, f in dup_folds.items() if len(f) > 1}
    assert not bad_s, f"세션이 여러 fold에 걸침: {list(bad_s)[:5]}"
    assert not bad_d, f"근사중복 클러스터가 여러 fold에 걸침: {list(bad_d)[:5]}"
    print(f"[검사 통과] 세션 {n_sessions}개, 근사중복 클러스터 "
          f"{len({r['dupc'] for r in items})}개 — 모두 단일 fold에 귀속", flush=True)

    for k in range(N_FOLDS):
        c = Counter_cls([r for r in items if r["fold"] == k])
        print(f"  fold{k}: {sum(c.values()):3d}장 {dict(c)}", flush=True)


def Counter_cls(rs):
    d = defaultdict(int)
    for r in rs:
        d[r["cls"]] += 1
    return d


def run_fold(k, items, device):
    test_items = [r for r in items if r["fold"] == k]
    rest_sess = sorted({r["session"] for r in items if r["fold"] != k})
    rnd = random.Random(SEED + 100 + k)
    rnd.shuffle(rest_sess)
    n_val_sess = max(1, len(rest_sess) // 8)
    val_sess = set(rest_sess[:n_val_sess])
    train_items = [r for r in items if r["fold"] != k and r["session"] not in val_sess]
    val_items = [r for r in items if r["fold"] != k and r["session"] in val_sess]

    tc = Counter_cls(train_items)
    for c in CLASSES:
        if tc[c] == 0:
            raise RuntimeError(f"fold {k}: train에 '{c}' 클래스가 0장 — 분할 재검토 필요")
    print(f"[fold {k}] train={len(train_items)} val={len(val_items)} test={len(test_items)}", flush=True)
    print(f"[fold {k}] train 클래스별: {dict(tc)}", flush=True)

    train_ds = ListDataset([(r["path"], r["ci"]) for r in train_items], TRAIN_TF)
    val_ds = ListDataset([(r["path"], r["ci"]) for r in val_items], EVAL_TF)
    test_ds = ListDataset([(r["path"], r["ci"]) for r in test_items], EVAL_TF)

    sw = [1.0 / tc[CLASSES[ci]] for _, ci in train_ds.items]
    sampler = WeightedRandomSampler(sw, num_samples=len(sw), replacement=True)
    train_loader = DataLoader(train_ds, batch_size=BATCH_SIZE, sampler=sampler, num_workers=0)
    val_loader = DataLoader(val_ds, batch_size=BATCH_SIZE, shuffle=False, num_workers=0)
    test_loader = DataLoader(test_ds, batch_size=BATCH_SIZE, shuffle=False, num_workers=0)

    fc = tc["front"]
    class_weights = torch.tensor([fc / tc[c] for c in CLASSES], dtype=torch.float).to(device)
    criterion = nn.CrossEntropyLoss(weight=class_weights)

    model = mobilenet_v3_small(weights=MobileNet_V3_Small_Weights.DEFAULT)
    model.classifier[3] = nn.Linear(model.classifier[3].in_features, len(CLASSES))
    model = model.to(device)

    def train_epoch(opt):
        model.train()
        tot, corr, n = 0.0, 0, 0
        for imgs, labels in train_loader:
            imgs, labels = imgs.to(device), labels.to(device)
            opt.zero_grad()
            out = model(imgs)
            loss = criterion(out, labels)
            loss.backward()
            opt.step()
            tot += loss.item() * imgs.size(0)
            corr += (out.argmax(1) == labels).sum().item()
            n += imgs.size(0)
        return tot / n, corr / n

    def eval_acc(loader):
        model.eval()
        corr, n = 0, 0
        with torch.no_grad():
            for imgs, labels in loader:
                imgs, labels = imgs.to(device), labels.to(device)
                corr += (model(imgs).argmax(1) == labels).sum().item()
                n += imgs.size(0)
        return corr / max(n, 1)

    for p in model.features.parameters():
        p.requires_grad = False
    opt = optim.Adam(filter(lambda p: p.requires_grad, model.parameters()), lr=LR_FROZEN)
    for e in range(EPOCHS_FROZEN):
        tl, ta = train_epoch(opt)
        print(f"[fold {k}] frozen {e+1:02d}/{EPOCHS_FROZEN} loss={tl:.4f} acc={ta:.4f} val={eval_acc(val_loader):.4f}", flush=True)

    for p in model.parameters():
        p.requires_grad = True
    opt = optim.Adam(model.parameters(), lr=LR_FINETUNE)
    sched = optim.lr_scheduler.CosineAnnealingLR(opt, T_max=EPOCHS_FINETUNE)
    best, best_state = -1.0, None
    for e in range(EPOCHS_FINETUNE):
        tl, ta = train_epoch(opt)
        va = eval_acc(val_loader)
        sched.step()
        print(f"[fold {k}] ft     {e+1:02d}/{EPOCHS_FINETUNE} loss={tl:.4f} acc={ta:.4f} val={va:.4f}", flush=True)
        if va > best:
            best, best_state = va, {kk: v.detach().cpu().clone() for kk, v in model.state_dict().items()}
    if best_state:
        model.load_state_dict(best_state)
    print(f"[fold {k}] best val_acc={best:.4f}", flush=True)

    model.eval()
    recs, idx = [], 0
    with torch.no_grad():
        for imgs, _ in test_loader:
            probs = torch.softmax(model(imgs.to(device)), dim=1).cpu().numpy()
            for row in probs:
                r = test_items[idx]
                recs.append({
                    "file": r["file"], "true": r["cls"], "fold": k,
                    "session": r["session"], "dupc": r["dupc"],
                    "probs": {CLASSES[j]: float(row[j]) for j in range(len(CLASSES))},
                })
                idx += 1
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    json.dump(recs, open(OUT_DIR / f"fold{k}_probs.json", "w"), ensure_ascii=False)
    print(f"[fold {k}] 완료 — held-out {len(recs)}장", flush=True)
    return recs


def decide(p):
    lab = max(p, key=p.get)
    t = FRONT_T if lab == "front" else (NONE_T if lab == "none" else DEV_T)
    return lab if p[lab] >= t else None


def report(recs, title, key=None):
    if key:
        seen, ded = set(), []
        for r in recs:
            if r[key] not in seen:
                seen.add(r[key])
                ded.append(r)
        recs = ded
    print("\n" + "=" * 76)
    print(f"{title}  (평가 표본 {len(recs)}장)")
    print("=" * 76)
    for cls in CLASSES:
        sub = [r for r in recs if r["true"] == cls]
        if not sub:
            continue
        hit = sum(1 for r in sub if decide(r["probs"]) == cls)
        lo, hi = wilson(hit, len(sub))
        pa = [r for r in recs if decide(r["probs"]) == cls]
        prec = sum(1 for r in pa if r["true"] == cls) / len(pa) if pa else float("nan")
        nones = sum(1 for r in sub if decide(r["probs"]) is None)
        print(f"  {cls:6s} recall={hit/len(sub):.3f} ({hit}/{len(sub)})  "
              f"95% CI [{lo:.3f}, {hi:.3f}]  precision={prec:.3f}  무판정={nones}")
    fr = [r for r in recs if r["true"] == "front"]
    if fr:
        fa = sum(1 for r in fr if decide(r["probs"]) in ("left", "right"))
        lo, hi = wilson(fa, len(fr))
        print(f"\n  front 오경보(직진->편향): {fa}/{len(fr)} = {fa/len(fr)*100:.1f}%  "
              f"95% CI [{lo*100:.1f}%, {hi*100:.1f}%]")
    print("\n  목표(left/right recall >= 90%) 판정:")
    for cls in ("left", "right"):
        sub = [r for r in recs if r["true"] == cls]
        if not sub:
            continue
        hit = sum(1 for r in sub if decide(r["probs"]) == cls)
        lo, hi = wilson(hit, len(sub))
        v = ("미달 확정" if hi < 0.90 else "달성 확정" if lo > 0.90 else "판정 불가 (CI가 90% 포함)")
        print(f"    {cls:6s}: {hit}/{len(sub)} = {hit/len(sub)*100:.1f}%  "
              f"CI [{lo*100:.1f}%, {hi*100:.1f}%] -> {v}")


def main():
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"Device: {device} | 세션간격 {SESSION_GAP_SEC}s | 중복임계 {DUP_PIXEL_THR} | {N_FOLDS}-fold", flush=True)
    items = load_images()
    n_sess = assign_sessions(items)
    n_dupc = dup_clusters(items)
    print(f"이미지 {len(items)}장 / 세션 {n_sess}개 / 근사중복 클러스터 {n_dupc}개", flush=True)
    split_folds(items, n_sess)

    all_recs = []
    for k in range(N_FOLDS):
        all_recs += run_fold(k, items, device)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    json.dump(all_recs, open(OUT_DIR / "all_probs.json", "w"), ensure_ascii=False)

    report(all_recs, "[주 지표] 세션단위 분할 + 근사중복 1장 집계", key="dupc")
    report(all_recs, "[참고] 세션단위 분할, 중복 미제거 전체 집계")


if __name__ == "__main__":
    main()
