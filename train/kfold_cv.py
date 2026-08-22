"""5-fold 교차검증 — 측정 정밀도 확보용 (신규 데이터 수집 불필요).

목적: 현재 test split이 전체의 10%(88장)뿐이라 클래스별 표본이 n=13~34로 작고,
      Wilson 95% 신뢰구간이 너무 넓어 "목표 90% 달성 여부"를 판정할 수 없다
      (docs/Tasks.md T1 "신뢰구간 산출 (2026-08-21)" 참조).
      k-fold를 쓰면 843장 전부가 "자신을 학습에 쓰지 않은 모델"의 평가 대상이
      되므로, 새 사진 없이 평가 표본이 클래스별 전체 개수까지 늘어난다.

주의 — 원본과의 차이 (결과 해석 시 반드시 감안할 것):
  train_model.py는 80/10/10(train/val/test)으로 나눈다.
  이 스크립트는 5-fold이므로 fold당 test=20%, 나머지 80%에서 val을 1/8 떼어
  train=70% / val=10% / test=20%가 된다.
  즉 fold별 학습 데이터가 원본(80%)보다 적으므로, 여기서 나오는 성능은
  배포 모델보다 **약간 낮게 나오는 보수적 추정**일 수 있다. 과대평가 위험은 없다.

그 외 학습 설정(transform, 모델, 샘플러, 클래스 가중치, 에폭/LR/스케줄러,
best-model 선택 기준)은 train_model.py와 동일하게 맞췄다.

산출물:
  train/kfold_out/fold{k}_probs.json — fold별 held-out 이미지의 softmax 확률
  train/kfold_out/all_probs.json     — 843장 전체 집계 (T49 Step 1에서 재사용 가능)
  표준출력                            — 임계값 적용 후 recall/precision + Wilson CI
"""
import json
import math
import os
import random
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
from PIL import Image
from torch.utils.data import DataLoader, Dataset, WeightedRandomSampler
from torchvision import transforms
from torchvision.models import MobileNet_V3_Small_Weights, mobilenet_v3_small

SEED = 42
random.seed(SEED)
np.random.seed(SEED)
torch.manual_seed(SEED)

REPO = Path(__file__).resolve().parent.parent
DATA_DIR = REPO / "image"
OUT_DIR = REPO / "train" / "kfold_out"

# 주의(정확성 필수): torchvision ImageFolder가 폴더명을 알파벳순으로 정렬해
# 부여하는 인덱스와 반드시 같아야 한다. front=0, left=1, none=2, right=3.
# 이 순서가 어긋나면 로짓이 엉뚱한 라벨에 매핑된다(classifier.dart:28과 동일 순서).
CLASSES = ["front", "left", "none", "right"]

IMG_SIZE = 224
BATCH_SIZE = 32
EPOCHS_FROZEN = 10
EPOCHS_FINETUNE = 10
LR_FROZEN = 1e-3
LR_FINETUNE = 1e-4
N_FOLDS = 5

# 앱 실제 임계값 — classifier.dart:33,38,39 및 eval_model.py:50-52와 동일해야 한다.
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
    """(경로, 라벨인덱스) 목록으로 만드는 Dataset. ImageFolder를 대신한다."""

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


def build_folds():
    """클래스별로 층화(stratified)해 N_FOLDS개로 나눈다."""
    per_class = {}
    for ci, cls in enumerate(CLASSES):
        files = sorted(
            f for f in os.listdir(DATA_DIR / cls)
            if f.lower().endswith((".jpg", ".jpeg", ".png"))
        )
        rnd = random.Random(SEED + ci)
        rnd.shuffle(files)
        per_class[cls] = [(str(DATA_DIR / cls / f), ci, f) for f in files]

    folds = [[] for _ in range(N_FOLDS)]
    for cls in CLASSES:
        for i, item in enumerate(per_class[cls]):
            folds[i % N_FOLDS].append(item)
    return folds


def build_model(device):
    model = mobilenet_v3_small(weights=MobileNet_V3_Small_Weights.DEFAULT)
    model.classifier[3] = nn.Linear(model.classifier[3].in_features, len(CLASSES))
    return model.to(device)


def run_fold(k, folds, device):
    test_items = folds[k]
    rest = [it for j in range(N_FOLDS) if j != k for it in folds[j]]
    # 원본의 80/10/10 비율에 맞추기 위해 나머지 80%에서 1/8(=전체 10%)을 val로 뗀다.
    rnd = random.Random(SEED + 100 + k)
    rnd.shuffle(rest)
    n_val = len(rest) // 8
    val_items, train_items = rest[:n_val], rest[n_val:]

    train_counts = {c: sum(1 for _, ci, _ in train_items if CLASSES[ci] == c) for c in CLASSES}
    print(f"[fold {k}] train={len(train_items)} val={len(val_items)} test={len(test_items)}", flush=True)
    print(f"[fold {k}] train 클래스별: {train_counts}", flush=True)

    train_ds = ListDataset([(p, ci) for p, ci, _ in train_items], TRAIN_TF)
    val_ds = ListDataset([(p, ci) for p, ci, _ in val_items], EVAL_TF)
    test_ds = ListDataset([(p, ci) for p, ci, _ in test_items], EVAL_TF)

    # train_model.py와 동일한 WeightedRandomSampler (1/클래스개수)
    sw = [1.0 / train_counts[CLASSES[ci]] for _, ci in train_ds.items]
    sampler = WeightedRandomSampler(sw, num_samples=len(sw), replacement=True)
    train_loader = DataLoader(train_ds, batch_size=BATCH_SIZE, sampler=sampler, num_workers=0)
    val_loader = DataLoader(val_ds, batch_size=BATCH_SIZE, shuffle=False, num_workers=0)
    test_loader = DataLoader(test_ds, batch_size=BATCH_SIZE, shuffle=False, num_workers=0)

    # train_model.py와 동일한 클래스 가중치 (front_count/count)
    fc = train_counts["front"]
    class_weights = torch.tensor(
        [fc / train_counts[c] for c in CLASSES], dtype=torch.float
    ).to(device)
    criterion = nn.CrossEntropyLoss(weight=class_weights)

    model = build_model(device)

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
        return corr / n

    # 1차: backbone frozen
    for p in model.features.parameters():
        p.requires_grad = False
    opt = optim.Adam(filter(lambda p: p.requires_grad, model.parameters()), lr=LR_FROZEN)
    for e in range(EPOCHS_FROZEN):
        tl, ta = train_epoch(opt)
        print(f"[fold {k}] frozen  {e+1:02d}/{EPOCHS_FROZEN} loss={tl:.4f} acc={ta:.4f} val={eval_acc(val_loader):.4f}", flush=True)

    # 2차: 전체 unfreeze fine-tuning, val_acc 최고 시점 채택
    for p in model.parameters():
        p.requires_grad = True
    opt = optim.Adam(model.parameters(), lr=LR_FINETUNE)
    sched = optim.lr_scheduler.CosineAnnealingLR(opt, T_max=EPOCHS_FINETUNE)
    best_acc, best_state = -1.0, None
    for e in range(EPOCHS_FINETUNE):
        tl, ta = train_epoch(opt)
        va = eval_acc(val_loader)
        sched.step()
        print(f"[fold {k}] ft      {e+1:02d}/{EPOCHS_FINETUNE} loss={tl:.4f} acc={ta:.4f} val={va:.4f}", flush=True)
        if va > best_acc:
            best_acc = va
            best_state = {kk: v.detach().cpu().clone() for kk, v in model.state_dict().items()}
    if best_state is not None:
        model.load_state_dict(best_state)
    print(f"[fold {k}] best val_acc={best_acc:.4f}", flush=True)

    # held-out fold 확률 산출
    model.eval()
    recs, idx = [], 0
    with torch.no_grad():
        for imgs, _ in test_loader:
            probs = torch.softmax(model(imgs.to(device)), dim=1).cpu().numpy()
            for row in probs:
                _, ci, fn = test_items[idx]
                recs.append({
                    "file": fn,
                    "true": CLASSES[ci],
                    "probs": {CLASSES[j]: float(row[j]) for j in range(len(CLASSES))},
                    "fold": k,
                })
                idx += 1
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    json.dump(recs, open(OUT_DIR / f"fold{k}_probs.json", "w"), ensure_ascii=False)
    print(f"[fold {k}] 완료 — held-out {len(recs)}장 확률 저장", flush=True)
    return recs


def decide(probs):
    lab = max(probs, key=probs.get)
    t = FRONT_T if lab == "front" else (NONE_T if lab == "none" else DEV_T)
    return lab if probs[lab] >= t else None


def report(recs):
    print("\n" + "=" * 74)
    print(f"5-fold 교차검증 집계 — 임계값 적용 (front={FRONT_T} / left,right={DEV_T} / none={NONE_T})")
    print(f"평가 표본: 843장 전체 (각 이미지는 자신을 학습하지 않은 모델이 판정)")
    print("=" * 74)
    for cls in CLASSES:
        sub = [r for r in recs if r["true"] == cls]
        hit = sum(1 for r in sub if decide(r["probs"]) == cls)
        lo, hi = wilson(hit, len(sub))
        pred_as = [r for r in recs if decide(r["probs"]) == cls]
        prec = sum(1 for r in pred_as if r["true"] == cls) / len(pred_as) if pred_as else float("nan")
        nones = sum(1 for r in sub if decide(r["probs"]) is None)
        print(f"  {cls:6s} recall={hit/len(sub):.3f} ({hit}/{len(sub)})  "
              f"95% CI [{lo:.3f}, {hi:.3f}]  precision={prec:.3f}  무판정={nones}")

    fr = [r for r in recs if r["true"] == "front"]
    fa = sum(1 for r in fr if decide(r["probs"]) in ("left", "right"))
    lo, hi = wilson(fa, len(fr))
    print(f"\n  front 오경보(직진->편향): {fa}/{len(fr)} = {fa/len(fr)*100:.1f}%  "
          f"95% CI [{lo*100:.1f}%, {hi*100:.1f}%]")

    print("\n  목표(left/right recall >= 90%) 판정:")
    for cls in ("left", "right"):
        sub = [r for r in recs if r["true"] == cls]
        hit = sum(1 for r in sub if decide(r["probs"]) == cls)
        lo, hi = wilson(hit, len(sub))
        if hi < 0.90:
            v = "미달 확정 (CI 상한이 90% 미만)"
        elif lo > 0.90:
            v = "달성 확정 (CI 하한이 90% 초과)"
        else:
            v = "판정 불가 (CI가 90%를 포함)"
        print(f"    {cls:6s}: {hit}/{len(sub)} = {hit/len(sub)*100:.1f}%  CI [{lo*100:.1f}%, {hi*100:.1f}%] -> {v}")


def main():
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"Device: {device}  |  {N_FOLDS}-fold", flush=True)
    folds = build_folds()
    print("fold별 장수:", [len(f) for f in folds], flush=True)

    all_recs = []
    for k in range(N_FOLDS):
        all_recs += run_fold(k, folds, device)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    json.dump(all_recs, open(OUT_DIR / "all_probs.json", "w"), ensure_ascii=False)
    report(all_recs)


if __name__ == "__main__":
    main()
