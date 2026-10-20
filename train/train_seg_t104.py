"""T104: 노면 분할 모델 학습 — LR-ASPP MobileNetV3-Small, 입력 224, 클래스 6.

클래스(사용자 확정, docs/Tasks.md T104 (7)): 0 배경 / 1 인도 / 2 차도 / 3 횡단보도 /
4 점자블록 선형 / 5 점자블록 점형. 캐시는 `seg_cache_t104.py`가 만든다.

평가 설계:
  - **폴더(촬영 세션) 단위 분할** 80/10/10 (train/val/test, seed 104). 같은 폴더
    사진은 연속 촬영이라 섞이면 누수다(T49 이래 이 프로젝트의 원칙).
  - val로 에폭별 최선 모델을 고르고, test는 마지막에 한 번만 잰다.
입력 형태(앱과 맞춤): 앱은 세로 프레임(3:4) 전체를 224x224로 누른다
  (`AngleEstimator.preprocessFrame(cropRatio: 1.0)`, 측정 러너와 같음). 가로
  1920x1080 사진에서 세로 3:4 영역(캐시 기준 240x320)을 잘라 224x224로 누른다.
  학습 = 무작위 가로 위치 + 좌우 반전 + 밝기/대비, 평가 = 가운데.
손실: 픽셀 교차엔트로피, 클래스 가중치 = sqrt(중앙 빈도 / 빈도)(train 픽셀 기준).
지표: 클래스별 IoU·mIoU, 그리고 앱 기능에 가까운 **발 앞 영역 판정**
  (가로 가운데 1/3 × 아래 1/2에 그 클래스가 5% 이상인가)의 재현율·정밀도.

환경변수: SEG_EPOCHS(기본 12), SEG_STEPS(에폭당 배치 수, 기본 = 전체), SEG_BATCH(16)
출력: model/crosswalk_surface_t104.{pt,onnx}, train/seg_t104_metrics.json
실행: python -u train/train_seg_t104.py
"""
import csv
import json
import math
import os
import random
import time

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image, ImageEnhance
from torch.utils.data import DataLoader, Dataset
from torchvision.models import MobileNet_V3_Small_Weights, mobilenet_v3_small
from torchvision.models.segmentation.lraspp import LRASPPHead

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(REPO, "train", "seg_cache_t104")
PT_OUT = os.path.join(REPO, "model", "crosswalk_surface_t104.pt")
ONNX_OUT = os.path.join(REPO, "model", "crosswalk_surface_t104.onnx")
METRICS_OUT = os.path.join(REPO, "train", "seg_t104_metrics.json")
N_CLS = 6
NAMES = ["배경", "인도", "차도", "횡단보도", "점자블록 선형", "점자블록 점형"]
SIZE = 224
CROP_W, CROP_H = 240, 320  # 캐시(569x320)에서 세로 3:4
EPOCHS = int(os.environ.get("SEG_EPOCHS", "12"))
STEPS = int(os.environ.get("SEG_STEPS", "0"))
BATCH = int(os.environ.get("SEG_BATCH", "16"))
THREADS = int(os.environ.get("SEG_THREADS", "4"))
WORKERS = int(os.environ.get("SEG_WORKERS", "2"))
VAL_MAX = int(os.environ.get("SEG_VAL_MAX", "0"))  # >0이면 에폭별 검증을 고정 표본으로 줄인다
SEED = 104
MEAN = np.array([0.485, 0.456, 0.406], np.float32)
STD = np.array([0.229, 0.224, 0.225], np.float32)


class LRASPPSmall(nn.Module):
    """MobileNetV3-Small 백본 + LR-ASPP 헤드(`bench_seg_t104.py`와 같은 구조)."""

    def __init__(self, n_cls, pretrained=True):
        super().__init__()
        w = MobileNet_V3_Small_Weights.DEFAULT if pretrained else None
        f = mobilenet_v3_small(weights=w).features
        self.low = f[:4]
        self.high = f[4:]
        self.head = LRASPPHead(24, 576, n_cls, 128)

    def forward(self, x):
        low = self.low(x)
        out = self.head({"low": low, "high": self.high(low)})
        return F.interpolate(out, size=x.shape[-2:], mode="bilinear", align_corners=False)


def split_folders(rows):
    folders = sorted({r["folder"] for r in rows})
    rng = random.Random(SEED)
    rng.shuffle(folders)
    n = len(folders)
    tr, va = set(folders[: int(n * 0.8)]), set(folders[int(n * 0.8): int(n * 0.9)])
    out = {"train": [], "val": [], "test": []}
    for r in rows:
        k = "train" if r["folder"] in tr else "val" if r["folder"] in va else "test"
        out[k].append(r["key"])
    return out


class SegSet(Dataset):
    def __init__(self, keys, train):
        self.keys, self.train = keys, train

    def __len__(self):
        return len(self.keys)

    def __getitem__(self, i):
        k = self.keys[i]
        im = Image.open(os.path.join(CACHE, "img", k + ".jpg")).convert("RGB")
        mk = Image.open(os.path.join(CACHE, "mask", k + ".png"))
        w = im.width
        x0 = random.randint(0, w - CROP_W) if self.train else (w - CROP_W) // 2
        box = (x0, 0, x0 + CROP_W, CROP_H)
        im = im.crop(box).resize((SIZE, SIZE), Image.BILINEAR)
        mk = mk.crop(box).resize((SIZE, SIZE), Image.NEAREST)
        if self.train:
            if random.random() < 0.5:
                im = im.transpose(Image.FLIP_LEFT_RIGHT)
                mk = mk.transpose(Image.FLIP_LEFT_RIGHT)
            im = ImageEnhance.Brightness(im).enhance(random.uniform(0.7, 1.3))
            im = ImageEnhance.Contrast(im).enhance(random.uniform(0.7, 1.3))
        a = (np.asarray(im, np.float32) / 255.0 - MEAN) / STD
        return torch.from_numpy(a.transpose(2, 0, 1).copy()), \
            torch.from_numpy(np.asarray(mk, np.int64).copy())


def _worker_init(_):
    torch.set_num_threads(1)


def class_weights(rows, keys):
    ks = set(keys)
    tot = np.zeros(N_CLS)
    cols = ["background", "sidewalk", "roadway", "crosswalk", "braille_linear", "braille_dot"]
    for r in rows:
        if r["key"] in ks:
            tot += [float(r[c]) for c in cols]
    f = tot / tot.sum()
    w = np.sqrt(np.median(f) / f)
    return torch.tensor(w / w.mean(), dtype=torch.float32), f


FRONT = (slice(SIZE // 2, SIZE), slice(SIZE // 3, 2 * SIZE // 3))


def evaluate(model, loader):
    model.eval()
    inter = np.zeros(N_CLS)
    union = np.zeros(N_CLS)
    conf = np.zeros((N_CLS, N_CLS), np.int64)
    front = {c: [0, 0, 0] for c in (1, 2, 3, 4, 5)}  # tp, gt, pred
    with torch.no_grad():
        for x, y in loader:
            p = model(x).argmax(1)
            for c in range(N_CLS):
                inter[c] += ((p == c) & (y == c)).sum().item()
                union[c] += ((p == c) | (y == c)).sum().item()
            conf += np.bincount((y.numpy() * N_CLS + p.numpy()).ravel(),
                                minlength=N_CLS * N_CLS).reshape(N_CLS, N_CLS)
            area = (SIZE - SIZE // 2) * (2 * SIZE // 3 - SIZE // 3)
            for c in front:
                g = (y[:, FRONT[0], FRONT[1]] == c).flatten(1).sum(1) >= 0.05 * area
                q = (p[:, FRONT[0], FRONT[1]] == c).flatten(1).sum(1) >= 0.05 * area
                front[c][0] += (g & q).sum().item()
                front[c][1] += g.sum().item()
                front[c][2] += q.sum().item()
    iou = inter / np.maximum(union, 1)
    return iou, conf, front


def export_onnx(model):
    model.eval()
    torch.onnx.export(model, torch.randn(1, 3, SIZE, SIZE), ONNX_OUT, input_names=["input"],
                      output_names=["output"], opset_version=12, dynamo=False)


def main():
    random.seed(SEED)
    torch.manual_seed(SEED)
    # 실측(2026-09-30): 이 PC는 스레드 4개가 최선(배치16 3.6s), 6·8개는 오히려
    # 6.8~7.5s. 데이터 작업 프로세스는 1스레드로 묶어 CPU 경합을 막는다.
    torch.set_num_threads(THREADS)
    with open(os.path.join(CACHE, "index.csv"), encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    sp = split_folders(rows)
    print(f"사진 {len(rows)} / 폴더 단위 분할: " +
          ", ".join(f"{k} {len(v)}" for k, v in sp.items()), flush=True)
    cw, freq = class_weights(rows, sp["train"])
    print("train 픽셀 비율:", " / ".join(f"{n} {v * 100:.2f}%" for n, v in zip(NAMES, freq)))
    print("클래스 가중치:", [round(float(v), 2) for v in cw], flush=True)

    vkeys = sp["val"]
    if VAL_MAX and len(vkeys) > VAL_MAX:
        vkeys = random.Random(SEED).sample(vkeys, VAL_MAX)
    print(f"에폭별 검증 {len(vkeys)}장, 최종 평가(test) {len(sp['test'])}장", flush=True)
    kw = dict(num_workers=WORKERS, worker_init_fn=_worker_init, persistent_workers=WORKERS > 0)
    tr = DataLoader(SegSet(sp["train"], True), batch_size=BATCH, shuffle=True,
                    drop_last=True, **kw)
    va = DataLoader(SegSet(vkeys, False), batch_size=32, **kw)
    te = DataLoader(SegSet(sp["test"], False), batch_size=32, **kw)

    model = LRASPPSmall(N_CLS)
    opt = torch.optim.AdamW(model.parameters(), lr=1e-3, weight_decay=1e-4)
    steps = STEPS or len(tr)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=1e-3, total_steps=EPOCHS * steps)
    lossf = nn.CrossEntropyLoss(weight=cw)
    best, hist = -1.0, []
    for ep in range(1, EPOCHS + 1):
        model.train()
        t0, tl, n = time.time(), 0.0, 0
        for x, y in tr:
            loss = lossf(model(x), y)
            opt.zero_grad()
            loss.backward()
            opt.step()
            sched.step()
            tl += loss.item()
            n += 1
            if n % 100 == 0:
                print(f"  [ep {ep}] {n}/{steps} loss {tl / n:.4f} "
                      f"({(time.time() - t0) / n:.2f}s/배치)", flush=True)
            if n >= steps:
                break
        iou, _, _ = evaluate(model, va)
        miou = float(iou.mean())
        hist.append({"epoch": ep, "loss": tl / n, "val_miou": miou, "val_iou": iou.tolist(),
                     "sec": time.time() - t0})
        print(f"[ep {ep}] loss {tl / n:.4f} val mIoU {miou:.3f} | " +
              " ".join(f"{nm} {v:.2f}" for nm, v in zip(NAMES, iou)) +
              f" | {time.time() - t0:.0f}s", flush=True)
        if miou > best:
            best = miou
            os.makedirs(os.path.dirname(PT_OUT), exist_ok=True)
            torch.save(model.state_dict(), PT_OUT)

    model.load_state_dict(torch.load(PT_OUT))
    iou, conf, front = evaluate(model, te)
    print("\n===== TEST (폴더 단위 홀드아웃, 최선 val 모델) =====")
    print(f"mIoU {iou.mean():.3f}")
    for nm, v in zip(NAMES, iou):
        print(f"  {nm:10s} IoU {v:.3f}")
    print("발 앞 영역(가운데 1/3 × 아래 1/2, 5% 이상) 판정:")
    for c, (tp, g, q) in front.items():
        print(f"  {NAMES[c]:10s} 재현 {tp}/{g} ({tp / max(g, 1) * 100:.1f}%)  "
              f"정밀도 {tp}/{q} ({tp / max(q, 1) * 100:.1f}%)")
    export_onnx(model)
    print(f"ONNX: {ONNX_OUT}")
    json.dump({"split": {k: len(v) for k, v in sp.items()}, "class_weights": cw.tolist(),
               "history": hist, "test_iou": iou.tolist(), "test_miou": float(iou.mean()),
               "test_confusion": conf.tolist(),
               "test_front": {NAMES[c]: v for c, v in front.items()}},
              open(METRICS_OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
