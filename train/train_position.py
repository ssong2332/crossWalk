"""T97: 횡단보도 내 **좌우 위치**(-2 왼쪽 끝 ~ +2 오른쪽 끝) 회귀 — 누수 없는 5-fold CV.

왜 (2026-09-16, 사용자 최종 목표):
  왼쪽 끝이면 직진·이탈과 무관하게 오른쪽으로, 오른쪽 끝이면 왼쪽으로 유도해
  사용자가 2~4(치우침~중앙) 안에서 건너게 한다. T95에서 이 규칙을 각도 라벨
  가중으로 넣어 봤지만 각도 모델은 배우지 못했다(직진&끝 21장 중 0장).
  그래서 위치를 **별도 출력**으로 학습하고 앱이 규칙으로 적용한다(스위치).

이 스크립트가 재는 것:
  "사진만 보고 끝(±2)인지 알아볼 수 있는가" — 끝 재현율/정밀도.
  못 알아보면 앱 규칙을 넣어도 동작하지 않으므로, 먼저 이것부터 측정한다.

설계:
  - 라벨: position_labels.csv(자체) + position_labels_surface.csv(AI Hub, 학습 전용)
    status=ok만. 5_crossed로 옮긴 사진 등 없는 파일은 건너뛴다.
  - 입력: EXIF 보정 **화면 전체**를 224x224로 (각도 모델의 중앙 크롭과 달리
    가장자리 단서를 살려야 한다). 좌우 반전 증강 -> position = -position.
  - 모델: MobileNetV3-Small + 1출력, 목표 = position / 2 (-1~+1), SmoothL1.
  - 세션/근사중복/fold는 train_angle.py의 것을 그대로 쓴다(누수 없음).
  - 끝 판정: |예측| >= EDGE_T(1.5) 이면 그 부호의 끝.

실행:
    python train/train_position.py
"""
import csv
import os
import random
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
import torchvision.transforms.functional as TF
from PIL import Image, ImageOps
from torch.utils.data import DataLoader, Dataset
from torchvision import transforms
from torchvision.models import MobileNet_V3_Small_Weights, mobilenet_v3_small

sys.path.insert(0, str(Path(__file__).resolve().parent))
import train_angle as ta  # noqa: E402  세션·중복·fold 재사용

REPO = Path(__file__).resolve().parent.parent
IMAGE_ROOT = REPO / "image"
EXTRA_DIR = REPO / "image_extra" / "on_surface_unlabeled"
POS_CSV = REPO / "train" / "position_labels.csv"
POS_SURFACE_CSV = REPO / "train" / "position_labels_surface.csv"
CACHE_DIR = REPO / "train" / "position_cache"
OUT_PRED = REPO / "train" / "position_cv_predictions.csv"
USE_SURFACE = os.environ.get("POSITION_USE_SURFACE", "1") == "1"

IMG_SIZE = 224
BATCH_SIZE = 32
EPOCHS_FROZEN = 10
EPOCHS_FINETUNE = 25
LR_FROZEN = 1e-3
LR_FINETUNE = 1e-4
SEED = 42
POS_SCALE = 2.0
EDGE_T = 1.5
NORM_MEAN = [0.485, 0.456, 0.406]
NORM_STD = [0.229, 0.224, 0.225]
CLASS_DIRS = ["1_approach", "2_front", "3_left", "4_right"]

random.seed(SEED)
np.random.seed(SEED)
torch.manual_seed(SEED)


def load_items():
    rows = []
    srcs = [(POS_CSV, False)] + ([(POS_SURFACE_CSV, True)] if USE_SURFACE else [])
    skipped_missing = 0
    for src, extra in srcs:
        if not src.exists():
            continue
        for r in csv.DictReader(open(src, encoding="utf-8")):
            if r["status"] != "ok" or r["position"] == "":
                continue
            p = (EXTRA_DIR / r["filename"]) if extra else (IMAGE_ROOT / r["class"] / r["filename"])
            if not p.exists():
                skipped_missing += 1
                continue
            rows.append({"path": str(p), "cls": r["class"], "file": r["filename"],
                         "position": int(r["position"]), "angle": 0.0, "extra": extra})
    from datetime import datetime
    import PIL.ExifTags as ExifTags
    for r in rows:
        if r["extra"]:
            r["dt"] = None
            continue
        ex = Image.open(r["path"])._getexif() or {}
        dt = None
        for k, v in ex.items():
            if ExifTags.TAGS.get(k) == "DateTimeOriginal":
                dt = datetime.strptime(v, "%Y:%m:%d %H:%M:%S")
        if dt is None:
            raise RuntimeError(f"EXIF 촬영시각 없음: {r['path']}")
        r["dt"] = dt
    print(f"위치 라벨 {len(rows)}장 로드 (파일 없음으로 건너뜀 {skipped_missing}장, "
          f"Surface 학습 전용 {sum(r['extra'] for r in rows)}장)")
    return rows


def cache_path(src: Path) -> Path:
    return CACHE_DIR / src.parent.name / (src.stem + ".png")


def build_cache(items):
    made = 0
    for r in items:
        src = Path(r["path"]); dst = cache_path(src)
        if dst.exists():
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        im = ImageOps.exif_transpose(Image.open(src)).convert("RGB")
        if r["extra"]:
            im = im.rotate(-90, expand=True)
        im = im.resize((IMG_SIZE, IMG_SIZE), Image.BILINEAR)  # 화면 전체, 크롭 없음
        im.save(dst, format="PNG", optimize=False)
        made += 1
    print(f"[캐시] 신규 {made}장, 총 {len(items)}장 (EXIF 보정, 전체 프레임)")


class PositionDataset(Dataset):
    def __init__(self, items, train):
        self.items, self.train = items, train
        self.jitter = transforms.ColorJitter(0.3, 0.3, 0.2, 0.05)

    def __len__(self):
        return len(self.items)

    def __getitem__(self, i):
        r = self.items[i]
        im = Image.open(cache_path(Path(r["path"]))).convert("RGB")
        pos = float(r["position"])
        if self.train:
            if random.random() < 0.5:
                im = TF.hflip(im); pos = -pos
            im = self.jitter(im)
        x = TF.normalize(TF.to_tensor(im), NORM_MEAN, NORM_STD)
        return x, torch.tensor([pos / POS_SCALE], dtype=torch.float32)


def build_model():
    m = mobilenet_v3_small(weights=MobileNet_V3_Small_Weights.DEFAULT)
    m.classifier[3] = nn.Linear(m.classifier[3].in_features, 1)
    return m


def run_epoch(model, loader, device, criterion, optimizer):
    model.train()
    tot, n = 0.0, 0
    for x, y in loader:
        x, y = x.to(device), y.to(device)
        optimizer.zero_grad()
        loss = criterion(model(x), y)
        loss.backward(); optimizer.step()
        tot += loss.item() * len(x); n += len(x)
    return tot / max(n, 1)


def predict(model, items, device):
    model.eval()
    loader = DataLoader(PositionDataset(items, train=False), batch_size=BATCH_SIZE, shuffle=False, num_workers=0)
    out = []
    with torch.no_grad():
        for x, _ in loader:
            x = x.to(device)
            p = model(x).squeeze(1)
            pf = -model(torch.flip(x, dims=[3])).squeeze(1)  # 반전 TTA
            out += ((p + pf) / 2 * POS_SCALE).cpu().tolist()
    return out


def main():
    print("=" * 78)
    print("T97: 좌우 위치 회귀 (누수 없는 세션 기반 5-fold CV)")
    print("=" * 78)
    items = load_items()
    n_sess = ta.assign_sessions(items)
    n_dup = ta.dup_clusters(items)
    print(f"세션 {n_sess}개, 근사중복 클러스터 {n_dup}개")
    ta.split_folds(items)
    build_cache(items)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    criterion = nn.SmoothL1Loss(beta=0.2)

    all_pred, all_items = [], []
    for k in range(ta.N_FOLDS):
        tr = [r for r in items if r["fold"] != k]
        te = [r for r in items if r["fold"] == k]
        print(f"\n[fold {k}] train {len(tr)} / test {len(te)}", flush=True)
        model = build_model().to(device)
        loader = DataLoader(PositionDataset(tr, train=True), batch_size=BATCH_SIZE, shuffle=True, num_workers=0)
        for p in model.features.parameters():
            p.requires_grad = False
        opt = optim.Adam(filter(lambda p: p.requires_grad, model.parameters()), lr=LR_FROZEN)
        for e in range(EPOCHS_FROZEN):
            print(f"  frozen  {e + 1}/{EPOCHS_FROZEN} loss {run_epoch(model, loader, device, criterion, opt):.4f}", flush=True)
        for p in model.parameters():
            p.requires_grad = True
        opt = optim.Adam(model.parameters(), lr=LR_FINETUNE)
        sched = optim.lr_scheduler.CosineAnnealingLR(opt, T_max=EPOCHS_FINETUNE)
        for e in range(EPOCHS_FINETUNE):
            loss = run_epoch(model, loader, device, criterion, opt); sched.step()
            print(f"  finetune {e + 1}/{EPOCHS_FINETUNE} loss {loss:.4f}", flush=True)
        preds = predict(model, te, device)
        all_pred += preds; all_items += te
        err = np.mean([abs(p - r["position"]) for p, r in zip(preds, te)])
        print(f"  -> fold {k} 위치 평균오차 {err:.2f} (단위: 위치 단계)")

    gt = np.array([r["position"] for r in all_items]); pr = np.array(all_pred)
    print("\n" + "=" * 78)
    print(f"결과 (자체 사진 {len(gt)}장, 평가는 자체만)")
    print("=" * 78)
    print(f"  위치 MAE {np.abs(pr - gt).mean():.2f} 단계 (기준선 '항상 0' {np.abs(gt).mean():.2f})")
    for t in (1.0, 1.5):
        for side, sign in (("왼쪽 끝(-2)", -1), ("오른쪽 끝(+2)", +1)):
            truth = gt == 2 * sign
            pred = (pr * sign) >= t
            tp = int((truth & pred).sum()); fp = int((~truth & pred).sum()); fn = int((truth & ~pred).sum())
            rec = tp / max(1, truth.sum()); prec = tp / max(1, pred.sum())
            print(f"  임계 {t}: {side:10} n={int(truth.sum()):3} 재현 {rec*100:5.1f}%  정밀도 {prec*100:5.1f}%  (오검출 {fp}장 중 치우침(±1) {int((~truth & pred & (gt * sign == 1)).sum())}, 중앙/반대 {int((~truth & pred & (gt * sign <= 0)).sum())})")
    # 3구간 혼동: 끝(-2)/안(-1..1)/끝(+2) at EDGE_T
    zone = lambda v: np.where(v <= -EDGE_T, -1, np.where(v >= EDGE_T, 1, 0))
    zg, zp = zone(gt), zone(pr)
    print(f"\n  3구간 혼동(임계 {EDGE_T}), 행=정답 열=예측 [왼쪽끝, 안, 오른쪽끝]:")
    for a, name in ((-1, "왼쪽끝"), (0, "안(-1~+1)"), (1, "오른쪽끝")):
        row = [int(((zg == a) & (zp == b)).sum()) for b in (-1, 0, 1)]
        print(f"    {name:10} {row}  (n={sum(row)})")
    # T98: 앱 끝 규칙은 횡단보도 위(front/left/right)에서만 쓰므로 approach 를 뺀 수치를 따로 낸다.
    on = np.array([r["cls"] != "1_approach" for r in all_items])
    g2, p2 = gt[on], pr[on]
    print(f"\n  [횡단보도 위만, approach 제외] n={int(on.sum())}")
    for t in (1.0, 1.5):
        for side, sign in (("왼쪽 끝(-2)", -1), ("오른쪽 끝(+2)", +1)):
            truth = g2 == 2 * sign
            pred = (p2 * sign) >= t
            tp = int((truth & pred).sum()); fp = int((~truth & pred).sum())
            rec = tp / max(1, truth.sum()); prec = tp / max(1, pred.sum())
            print(f"  임계 {t}: {side:10} n={int(truth.sum()):3} 재현 {rec*100:5.1f}%  정밀도 {prec*100:5.1f}%  (오검출 {fp}장 중 치우침(±1) {int((~truth & pred & (g2 * sign == 1)).sum())}, 중앙/반대 {int((~truth & pred & (g2 * sign <= 0)).sum())})")
        wrong = int((((g2 <= -1) & (p2 >= t)) | ((g2 >= 1) & (p2 <= -t))).sum())
        print(f"  임계 {t}: 반대 방향 유도 {wrong}장")
    with open(OUT_PRED, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f); w.writerow(["class", "filename", "gt_position", "pred_position"])
        for r, p in zip(all_items, all_pred):
            w.writerow([r["cls"], r["file"], r["position"], f"{p:.3f}"])
    print(f"\n예측값 저장: {OUT_PRED}")


if __name__ == "__main__":
    main()
