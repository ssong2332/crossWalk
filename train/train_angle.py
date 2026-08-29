"""T69: 횡단보도 진행 방향 각도 회귀 모델 학습 (A안 2단계).

배경 — 왜 학습인가:
  고전 CV(`StripeDirectionEstimator`)를 사람 라벨 405장 기준으로 실측한 결과
  **평균 절대오차 34.5도**로, 아무것도 학습하지 않은 "항상 0도" 기준선(32.4도)
  보다도 나빴다. 클래스별로 보면 front는 2.7도로 맞지만 left 61.3도 /
  right 45.1도로 완전히 실패 — 즉 정답이 0에 가까울 때만 맞고 정작 중요한
  이탈 상황에서 못 맞춘다. 원근 때문에 "하나의 대표 줄무늬 각도"가 잘 정의되지
  않는 것이 원인이며 파라미터 튜닝으로 풀 문제가 아니다(T67-2).

이 스크립트가 하는 일:
  `train/angle_labels.csv`(사람이 매긴 진행 방향 각도)로 회귀 모델을 학습하고,
  **누수 없는 세션 기반 교차검증**으로 성능을 측정한다.

핵심 주의사항 3가지 (하나라도 틀리면 조용히 오작동한다):

1. **EXIF 방향** — 라벨은 `label_angles.py`가 `ImageOps.exif_transpose`로 보정한
   **화면(세로) 방향** 기준으로 매겨졌다. 반면 기존 분류기 파이프라인
   (`build_cache.py`)은 EXIF 보정을 **일부러 하지 않는다**(T57 미해결 이슈).
   따라서 이 스크립트는 분류기 캐시를 쓰지 않고 **자체 EXIF 보정 캐시**를 만든다.
   => 앱 통합 시 이 모델에는 **화면 방향으로 회전된 프레임**을 넣어야 한다.
      회전 없이 넣으면 예측이 약 90도 계통 오차를 갖는다(검증 가능한 예측).

2. **증강이 각도도 바꾼다** — 기하 증강은 정답 각도를 함께 변환해야 한다.
   실측으로 확정한 규칙(합성 화살표 이미지로 9개 케이스 전수 확인):
     - 좌우 반전(hflip)      -> angle = -angle
     - 회전 TF.rotate(theta) -> angle = angle - theta
   기존 파이프라인의 `RandomHorizontalFlip`/`RandomRotation`을 그대로 쓰면
   이미지만 바뀌고 라벨은 안 바뀌어 학습이 망가진다. 그래서 증강을 직접 구현한다.

3. **누수 없는 분할** — T1에서 확인됐듯 이 데이터셋은 93.6%가 연사 프레임이라
   무작위 분할 시 같은 장면이 train/test에 갈린다(성능이 부풀려짐).
   `groupkfold_cv.py`와 **동일한** 기준으로 세션(EXIF 촬영시각 60초 간격)과
   근사중복 클러스터(64x64 그레이 평균 픽셀차 < 10)를 묶고, 통째로 한 fold에만
   넣는다. 분할 직후 assert로 강제 검사한다.

실행:
    python train/train_angle.py
"""

import csv
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
from PIL import Image, ImageOps, ExifTags
from torch.utils.data import DataLoader, Dataset
from torchvision import transforms
from torchvision.models import mobilenet_v3_small, MobileNet_V3_Small_Weights
import torchvision.transforms.functional as TF

SEED = 42
random.seed(SEED)
np.random.seed(SEED)
torch.manual_seed(SEED)

REPO = Path(__file__).resolve().parent.parent
DATA_DIR = REPO / "image"
LABEL_CSV = REPO / "train" / "angle_labels.csv"
CACHE_DIR = REPO / "train" / "angle_cache"
MODEL_OUT = REPO / "model" / "crosswalk_angle.pt"

IMG_SIZE = 224
# 회전 증강이 검은 모서리를 만들지 않도록 캐시는 조금 크게 저장하고,
# 회전 후 중앙을 IMG_SIZE로 잘라 쓴다.
CACHE_SIZE = 288

N_FOLDS = 5
BATCH_SIZE = 32
EPOCHS_FROZEN = 10
EPOCHS_FINETUNE = 25
LR_FROZEN = 1e-3
LR_FINETUNE = 1e-4
MAX_ROT_DEG = 15.0

# 각도를 이 값으로 나눠 정규화한다(라벨 범위가 대략 +-80도).
ANGLE_SCALE = 90.0

# groupkfold_cv.py와 동일한 기준 — 바꾸면 기존 측정과 비교가 깨진다.
SESSION_GAP_SEC = 60
DUP_PIXEL_THR = 10.0

NORM_MEAN = [0.485, 0.456, 0.406]
NORM_STD = [0.229, 0.224, 0.225]


# ── 1. 라벨 + 이미지 목록 ────────────────────────────────────────────
def load_labeled_items():
    """라벨 CSV를 읽고 EXIF 촬영시각을 붙여 목록을 만든다."""
    rows = []
    with open(LABEL_CSV, encoding="utf-8") as f:
        for r in csv.DictReader(f):
            if r["status"] != "ok" or not r["angle_deg"]:
                continue
            p = DATA_DIR / r["class"] / r["filename"]
            if not p.exists():
                raise RuntimeError(f"라벨에 있는 파일이 없음: {p}")
            rows.append({
                "path": str(p),
                "cls": r["class"],
                "file": r["filename"],
                "angle": float(r["angle_deg"]),
            })

    for r in rows:
        ex = Image.open(r["path"])._getexif() or {}
        dt = None
        for k, v in ex.items():
            if ExifTags.TAGS.get(k) == "DateTimeOriginal":
                dt = datetime.strptime(v, "%Y:%m:%d %H:%M:%S")
        if dt is None:
            raise RuntimeError(f"EXIF 촬영시각 없음: {r['path']} — 세션 분할 불가")
        r["dt"] = dt
    return rows


# ── 2. 세션 / 근사중복 (groupkfold_cv.py와 동일 기준) ────────────────
def assign_sessions(items):
    items.sort(key=lambda r: r["dt"])
    sid, prev = 0, None
    for r in items:
        if prev is not None and (r["dt"] - prev).total_seconds() > SESSION_GAP_SEC:
            sid += 1
        r["session"] = sid
        prev = r["dt"]
    return sid + 1


def dup_clusters(items):
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


def split_folds(items):
    by_sess = defaultdict(list)
    for r in items:
        by_sess[r["session"]].append(r)

    load = [0] * N_FOLDS
    fold_of = {}
    for s in sorted(by_sess, key=lambda s: -len(by_sess[s])):
        best = min(range(N_FOLDS), key=lambda k: load[k])
        fold_of[s] = best
        load[best] += len(by_sess[s])
    for r in items:
        r["fold"] = fold_of[r["session"]]

    # 누수 없음 하드 검사 — 위반 시 즉시 중단한다.
    sess_folds, dup_folds = defaultdict(set), defaultdict(set)
    for r in items:
        sess_folds[r["session"]].add(r["fold"])
        dup_folds[r["dupc"]].add(r["fold"])
    bad_s = {s: f for s, f in sess_folds.items() if len(f) > 1}
    bad_d = {d: f for d, f in dup_folds.items() if len(f) > 1}
    assert not bad_s, f"세션이 여러 fold에 걸침: {list(bad_s)[:5]}"
    assert not bad_d, f"근사중복 클러스터가 여러 fold에 걸침: {list(bad_d)[:5]}"
    print(f"[검사 통과] 세션 {len(by_sess)}개 / 근사중복 클러스터 "
          f"{len({r['dupc'] for r in items})}개 — 모두 단일 fold에 귀속")
    print(f"  fold별 장수: {load}")


# ── 3. EXIF 보정 캐시 ────────────────────────────────────────────────
def cache_path(src: Path) -> Path:
    return CACHE_DIR / src.parent.name / (src.stem + ".png")


def build_cache(items):
    """EXIF 보정 + CACHE_SIZE 리사이즈를 미리 계산해 둔다.

    분류기용 `build_cache.py`는 EXIF 보정을 일부러 하지 않으므로 재사용할 수
    없다(라벨이 보정된 방향 기준이라 방향이 90도 어긋난다).
    """
    made = 0
    for r in items:
        src = Path(r["path"])
        dst = cache_path(src)
        if dst.exists():
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        im = ImageOps.exif_transpose(Image.open(src)).convert("RGB")
        im = im.resize((CACHE_SIZE, CACHE_SIZE), Image.BILINEAR)
        im.save(dst, format="PNG", optimize=False)
        made += 1
    print(f"[캐시] 신규 {made}장 생성, 총 {len(items)}장 (EXIF 보정 적용)")


# ── 4. 각도를 함께 변환하는 데이터셋 ─────────────────────────────────
class AngleDataset(Dataset):
    """이미지와 **각도 라벨을 함께** 증강한다.

    기하 증강 규칙(실측 확정):
      - 좌우 반전  -> angle = -angle
      - rotate(th) -> angle = angle - th
    """

    def __init__(self, items, train: bool):
        self.items = items
        self.train = train
        self.jitter = transforms.ColorJitter(
            brightness=0.3, contrast=0.3, saturation=0.2, hue=0.05)

    def __len__(self):
        return len(self.items)

    def __getitem__(self, i):
        r = self.items[i]
        im = Image.open(cache_path(Path(r["path"]))).convert("RGB")
        angle = r["angle"]

        if self.train:
            if random.random() < 0.5:
                im = TF.hflip(im)
                angle = -angle
            th = random.uniform(-MAX_ROT_DEG, MAX_ROT_DEG)
            im = TF.rotate(im, th)
            angle = angle - th
            im = self.jitter(im)

        # 회전으로 생긴 모서리를 버리기 위해 중앙을 잘라 쓴다.
        im = TF.center_crop(im, [IMG_SIZE, IMG_SIZE])
        x = TF.normalize(TF.to_tensor(im), NORM_MEAN, NORM_STD)
        return x, torch.tensor([angle / ANGLE_SCALE], dtype=torch.float32)


# ── 5. 모델 ──────────────────────────────────────────────────────────
def build_model():
    m = mobilenet_v3_small(weights=MobileNet_V3_Small_Weights.DEFAULT)
    m.classifier[3] = nn.Linear(m.classifier[3].in_features, 1)
    return m


def run_epoch(model, loader, device, criterion, optimizer=None):
    train = optimizer is not None
    model.train() if train else model.eval()
    total, n = 0.0, 0
    with torch.set_grad_enabled(train):
        for x, y in loader:
            x, y = x.to(device), y.to(device)
            out = model(x)
            loss = criterion(out, y)
            if train:
                optimizer.zero_grad()
                loss.backward()
                optimizer.step()
            total += loss.item() * x.size(0)
            n += x.size(0)
    return total / max(n, 1)


def predict(model, items, device):
    """좌우반전 TTA로 예측한다.

    반전하면 정답 각도의 부호가 뒤집히므로(실측 확정), 반전 입력의 예측을
    다시 부호 반전해 원본 예측과 평균낸다. 좌/우 어느 쪽으로도 치우치지
    않게 만들어 계통 편향을 줄인다.
    """
    model.eval()
    loader = DataLoader(AngleDataset(items, train=False),
                        batch_size=BATCH_SIZE, shuffle=False, num_workers=0)
    preds = []
    with torch.no_grad():
        for x, _ in loader:
            x = x.to(device)
            a = model(x).cpu().numpy().ravel()
            b = -model(torch.flip(x, dims=[3])).cpu().numpy().ravel()
            preds += ((a + b) / 2 * ANGLE_SCALE).tolist()
    return preds


# ── 6. 지표 ──────────────────────────────────────────────────────────
def report(name, errs):
    if not errs:
        print(f"  {name}: 데이터 없음")
        return
    errs = np.array(errs)
    line = (f"  {name:<22} n={len(errs):>3}  평균 {errs.mean():>5.1f}도  "
            f"중앙 {np.median(errs):>5.1f}도")
    for t in (10, 15, 20):
        line += f"  ±{t}도내 {(errs <= t).mean() * 100:>3.0f}%"
    print(line)


def main():
    print("=" * 78)
    print("T69: 진행 방향 각도 회귀 학습 (누수 없는 세션 기반 5-fold CV)")
    print("=" * 78)

    items = load_labeled_items()
    print(f"라벨 {len(items)}장 로드")
    n_sess = assign_sessions(items)
    n_dup = dup_clusters(items)
    print(f"세션 {n_sess}개, 근사중복 클러스터 {n_dup}개")
    split_folds(items)
    build_cache(items)

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"device: {device}")

    criterion = nn.SmoothL1Loss(beta=0.2)
    all_pred, all_gt, all_cls = [], [], []

    for k in range(N_FOLDS):
        tr = [r for r in items if r["fold"] != k]
        te = [r for r in items if r["fold"] == k]
        print(f"\n[fold {k}] train {len(tr)} / test {len(te)}")

        model = build_model().to(device)
        tr_loader = DataLoader(AngleDataset(tr, train=True),
                               batch_size=BATCH_SIZE, shuffle=True, num_workers=0)

        for p in model.features.parameters():
            p.requires_grad = False
        opt = optim.Adam(filter(lambda p: p.requires_grad, model.parameters()), lr=LR_FROZEN)
        for e in range(EPOCHS_FROZEN):
            loss = run_epoch(model, tr_loader, device, criterion, opt)
            print(f"  frozen  {e + 1}/{EPOCHS_FROZEN} loss {loss:.4f}", flush=True)

        for p in model.parameters():
            p.requires_grad = True
        opt = optim.Adam(model.parameters(), lr=LR_FINETUNE)
        # 코사인 감쇠 — 후반부에 학습률을 낮춰 손실이 튀지 않고 수렴하게 한다.
        sched = optim.lr_scheduler.CosineAnnealingLR(opt, T_max=EPOCHS_FINETUNE)
        for e in range(EPOCHS_FINETUNE):
            loss = run_epoch(model, tr_loader, device, criterion, opt)
            sched.step()
            print(f"  finetune {e + 1}/{EPOCHS_FINETUNE} loss {loss:.4f}", flush=True)

        preds = predict(model, te, device)
        for r, p in zip(te, preds):
            all_pred.append(p)
            all_gt.append(r["angle"])
            all_cls.append(r["cls"])
        fold_err = [abs(p - r["angle"]) for r, p in zip(te, preds)]
        print(f"  -> fold {k} 평균오차 {np.mean(fold_err):.1f}도")

    print("\n" + "=" * 78)
    print("결과 (누수 없는 교차검증, 전체 홀드아웃 예측)")
    print("=" * 78)
    errs = [abs(p - g) for p, g in zip(all_pred, all_gt)]
    report("학습 모델", errs)
    report("기준선: 항상 0도", [abs(g) for g in all_gt])
    m = float(np.mean(all_gt))
    report(f"기준선: 항상 평균({m:.0f}도)", [abs(g - m) for g in all_gt])
    print("  기존 고전 CV           n=387  평균  34.5도  중앙  35.9도"
          "  ±10도내  37%  ±15도내  39%  ±20도내  40%   (별도 측정)")

    print("\n  클래스별 (학습 모델):")
    by = defaultdict(list)
    for c, p, g in zip(all_cls, all_pred, all_gt):
        by[c].append(abs(p - g))
    for c in sorted(by):
        report(f"    {c}", by[c])

    # 진단용: 예측값을 그대로 저장해 나중에 분석할 수 있게 한다
    # (큰 각도를 평균 쪽으로 축소 예측하는지 등).
    pred_csv = REPO / "train" / "angle_cv_predictions.csv"
    with open(pred_csv, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["class", "gt_deg", "pred_deg", "abs_err"])
        for c, g, p_ in zip(all_cls, all_gt, all_pred):
            w.writerow([c, f"{g:.2f}", f"{p_:.2f}", f"{abs(p_ - g):.2f}"])
    print(f"\n예측값 저장: {pred_csv}")

    torch.save(model.state_dict(), MODEL_OUT)
    print(f"\n마지막 fold 모델 저장: {MODEL_OUT}")
    print("주의: 이 저장본은 fold 4 학습분이라 배포용이 아니다. "
          "배포 모델은 전체 데이터로 다시 학습해야 한다.")


if __name__ == "__main__":
    main()
