"""T159: 이탈 단계를 분명히 가르는 각도 모델 — 학습(CV)·최종·ONNX.

데이터·fold·정답은 T151과 같다(`t151_angle_retrain.load_all`: 기존 1,027 기하 + T150 304,
세션 60초·근사중복 / T150 묶음 fold). 기본 레시피도 T151(`train_angle`)과 같고 바꾸는 것만:
  - 머리: 회귀 1 + 순서형(|각| > 컷) K개 + 방향(오른쪽 확률) 1. 순서형 정답은 부드럽게
    σ((|a|−c)/SOFT)로 준다(라벨 잡음 반영). 회전 증강 뒤 각도로 다시 계산한다.
  - T150(앱 프레임 = 실제 입력과 같은 영역) 표본 가중 T150_W.
  - 입력 크기 IMG(224 = 앱과 같음 / 288 = 앱 입력 변경). 시야는 같게 둔다(캐시 = IMG×288/224).
출력 CSV 열: reg/ord/sgn × plain/flip — 평가(`t159_report.py`)에서 점수를 조합한다.

실행 (저장소 루트, 이미지는 T151_DATA_ROOT):
    python train/t159_train.py cv <이름> [--img 224] [--t150w 2] [--threads 2]
    python train/t159_train.py final <이름> [같은 옵션]   # 전량 학습 + ONNX(model/t159/, git 제외)
"""

import argparse
import csv
import hashlib
import random
import sys
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
import torchvision.transforms.functional as TF
from PIL import Image, ImageOps
from torch.utils.data import DataLoader, Dataset
from torchvision import transforms

sys.path.insert(0, str(Path(__file__).resolve().parent))
import t151_angle_retrain as t151  # noqa: E402
import train_angle as ta  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "train" / "t159"
MODEL_DIR = REPO / "model" / "t159"  # /model/ 은 .gitignore 대상

CUTS = [8.0, 12.0, 16.0, 20.0, 25.0, 30.0, 35.0, 40.0]
SOFT = 2.0          # 순서형 부드러운 정답의 폭(도)
SIGN_MIN = 5.0      # |각| 이 이보다 작으면 방향 손실을 주지 않는다
W_ORD, W_SIGN = 1.0, 0.3
# 후보마다 바꾸는 값(명령줄 옵션으로 덮어씀). 기본값 = ord224/ord288 첫 후보.
OPT = {"cons": 0.0,    # >0: 좌우반전 일관성 — 반전 입력도 함께 학습하고 두 예측 차이를 벌한다
       "bigw": 1.0,    # |각| ≥ BIG_DEG 표본 가중 배수
       "big_deg": 25.0,
       "rot": 15.0,    # 회전 보강 범위 ±도(기본 = ta.MAX_ROT_DEG). 회전 후 |각| > 90이면 그 표본은 회전 안 함
       "crop": 224 / 288}  # 시야 = 중앙 크롭 비율(앱 AngleEstimator.cropRatio). 1.0 = 화면 전체(앱 입력 변경)


def ord_abs(p):
    """순서형 확률 [.., K] → |각| 점수 Σ P(>c_k)·(c_k − c_{k−1})."""
    w = torch.tensor(np.diff([0.0] + CUTS), dtype=p.dtype, device=p.device)
    return (p * w).sum(-1)


class Head(nn.Module):
    def __init__(self, img):
        super().__init__()
        self.net = ta.build_model()
        self.net.classifier[3] = nn.Linear(self.net.classifier[3].in_features, 2 + len(CUTS))
        self.img = img

    def forward(self, x):
        return self.net(x)  # [:,0]=회귀(÷90), [:,1:1+K]=순서형 로짓, [:,-1]=방향 로짓


class Export(nn.Module):
    """ONNX용: 앱과 같은 [1,1] 출력(각도/90). 점수 = 방향 부호 × 순서형 |각|."""

    def __init__(self, head, score):
        super().__init__()
        self.head, self.score = head, score

    def forward(self, x):
        o = self.head(x)
        if self.score == "reg":
            return o[:, :1]
        a = ord_abs(torch.sigmoid(o[:, 1:1 + len(CUTS)]))
        sg = torch.where(o[:, -1:] >= 0, 1.0, -1.0) if self.score == "ord_sgn" else torch.sign(o[:, :1])
        return sg * a[:, None] / ta.ANGLE_SCALE


class DS(Dataset):
    def __init__(self, items, train, img):
        self.items, self.train, self.img = items, train, img
        self.cache = round(img / OPT["crop"])
        self.jitter = transforms.ColorJitter(brightness=0.3, contrast=0.3, saturation=0.2, hue=0.05)

    def __len__(self):
        return len(self.items)

    def __getitem__(self, i):
        r = self.items[i]
        im = Image.open(cache_path(r, self.cache)).convert("RGB")
        a = r["angle"]
        if self.train:
            if random.random() < 0.5:
                im, a = TF.hflip(im), -a
            th = random.uniform(-OPT["rot"], OPT["rot"])
            if abs(a - th) <= 90:
                im, a = TF.rotate(im, th), a - th
            im = self.jitter(im)
        im = TF.center_crop(im, [self.img, self.img])
        x = TF.normalize(TF.to_tensor(im), ta.NORM_MEAN, ta.NORM_STD)
        return x, torch.tensor([a, r["w"]], dtype=torch.float32)


def cache_path(r, size):
    if size == ta.CACHE_SIZE:
        return t151.cache_path(r)
    return REPO / "train" / f"angle_cache_{size}" / Path(r["path"]).parent.name / (Path(r["path"]).stem + ".png")


def build_cache(items, size):
    if size == ta.CACHE_SIZE:
        return
    made = 0
    for r in items:
        dst = cache_path(r, size)
        if dst.exists():
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        im = ImageOps.exif_transpose(Image.open(r["path"])).convert("RGB")
        if r["frame"]:
            im = im.rotate(-90, expand=True)
        im.resize((size, size), Image.BILINEAR).save(dst, format="PNG", optimize=False)
        made += 1
    print(f"[캐시 {size}] 신규 {made}장", flush=True)


def loss_fn(o, y):
    a, w = y[:, 0], y[:, 1]
    reg = nn.functional.smooth_l1_loss(o[:, 0], a / ta.ANGLE_SCALE, beta=0.2, reduction="none")
    c = torch.tensor(CUTS, device=o.device)
    tgt = torch.sigmoid((a.abs()[:, None] - c) / SOFT)
    ordl = nn.functional.binary_cross_entropy_with_logits(o[:, 1:1 + len(CUTS)], tgt,
                                                          reduction="none").mean(1)
    m = (a.abs() >= SIGN_MIN).float()
    sg = nn.functional.binary_cross_entropy_with_logits(o[:, -1], (a > 0).float(), reduction="none") * m
    w = w * torch.where(a.abs() >= OPT["big_deg"], OPT["bigw"], 1.0)
    return ((reg + W_ORD * ordl + W_SIGN * sg) * w).sum() / w.sum()


def cons_loss(o, of):
    """o = 원본 출력, of = 좌우반전 입력 출력. 회귀는 부호 반대, 순서형은 같게, 방향은 반대."""
    K = len(CUTS)
    reg = ((o[:, 0] + of[:, 0]) ** 2).mean()
    ordc = ((torch.sigmoid(o[:, 1:1 + K]) - torch.sigmoid(of[:, 1:1 + K])) ** 2).mean()
    sg = ((torch.sigmoid(o[:, -1]) - (1 - torch.sigmoid(of[:, -1]))) ** 2).mean()
    return reg * 10 + ordc + sg


def run_epoch(model, loader, opt):
    model.train()
    tot, n = 0.0, 0
    for x, y in loader:
        if OPT["cons"] > 0:
            o = model(torch.cat([x, torch.flip(x, dims=[3])]))
            o, of = o[:len(x)], o[len(x):]
            yf = y.clone()
            yf[:, 0] = -yf[:, 0]
            loss = (loss_fn(o, y) + loss_fn(of, yf)) / 2 + OPT["cons"] * cons_loss(o, of)
        else:
            loss = loss_fn(model(x), y)
        opt.zero_grad()
        loss.backward()
        opt.step()
        tot += loss.item() * x.size(0)
        n += x.size(0)
    return tot / n


def train_model(tr, img):
    model = Head(img)
    loader = DataLoader(DS(tr, True, img), batch_size=ta.BATCH_SIZE, shuffle=True, num_workers=0)
    for p in model.net.features.parameters():
        p.requires_grad = False
    opt = optim.Adam([p for p in model.parameters() if p.requires_grad], lr=ta.LR_FROZEN)
    for e in range(ta.EPOCHS_FROZEN):
        print(f"  frozen  {e + 1}/{ta.EPOCHS_FROZEN} loss {run_epoch(model, loader, opt):.4f}", flush=True)
    for p in model.parameters():
        p.requires_grad = True
    opt = optim.Adam(model.parameters(), lr=ta.LR_FINETUNE)
    sched = optim.lr_scheduler.CosineAnnealingLR(opt, T_max=ta.EPOCHS_FINETUNE)
    for e in range(ta.EPOCHS_FINETUNE):
        loss = run_epoch(model, loader, opt)
        sched.step()
        print(f"  finetune {e + 1}/{ta.EPOCHS_FINETUNE} loss {loss:.4f}", flush=True)
    return model


def predict(model, items, img):
    """행마다 (reg, ord|각|, P(오른쪽)) × (원본, 좌우반전→부호 되돌림)."""
    model.eval()
    loader = DataLoader(DS(items, False, img), batch_size=ta.BATCH_SIZE, shuffle=False, num_workers=0)
    out = []
    with torch.no_grad():
        for x, _ in loader:
            res = []
            for flip in (False, True):
                o = model(torch.flip(x, dims=[3]) if flip else x)
                s = -1.0 if flip else 1.0
                reg = s * o[:, 0] * ta.ANGLE_SCALE
                oa = ord_abs(torch.sigmoid(o[:, 1:1 + len(CUTS)]))
                pr = torch.sigmoid(o[:, -1])
                pr = 1 - pr if flip else pr
                res.append(torch.stack([reg, oa, pr], 1))
            out += torch.cat(res, 1).tolist()
    return out


COLS = ["reg_plain", "ord_plain", "pr_plain", "reg_flip", "ord_flip", "pr_flip"]


def prep(args):
    torch.set_num_threads(args.threads)
    OPT.update(cons=args.cons, bigw=args.bigw, big_deg=args.big_deg, rot=args.rot, crop=args.crop)
    print(f"[설정] img={args.img} t150w={args.t150w} {OPT}", flush=True)
    ex, t1 = t151.load_all()
    t151.set_target(ex + t1, "G")
    for r in ex:
        r["w"] = 1.0
    for r in t1:
        r["w"] = args.t150w
    build_cache(ex + t1, round(args.img / OPT["crop"]))
    return ex, t1


def cmd_cv(args):
    OUT.mkdir(parents=True, exist_ok=True)
    ex, t1 = prep(args)
    rows, t0 = [], time.time()
    for k in range(ta.N_FOLDS):
        t151.seed_all(ta.SEED + k)
        tr = [r for r in ex + t1 if r["fold"] != k]
        te = [r for r in ex + t1 if r["fold"] == k]
        print(f"\n[{args.name} fold {k}] train {len(tr)} / test {len(te)} "
              f"(경과 {(time.time() - t0) / 60:.1f}분)", flush=True)
        model = train_model(tr, args.img)
        pr = predict(model, te, args.img)
        rows += list(zip(te, pr))
        e = [abs((p[0] + p[3]) / 2 - r["angle"]) for r, p in zip(te, pr) if r["src"] == "t150"]
        print(f"  -> fold {k} T150 reg TTA MAE {np.mean(e):.1f}도", flush=True)
    path = OUT / f"cv_pred_{args.name}.csv"
    with open(path, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["src", "class", "filename", "fold", "group", "geo_deg", "pos"] + COLS)
        for r, p in rows:
            w.writerow([r["src"], r["cls"], r["file"], r["fold"], r.get("group", r.get("session")),
                        f"{r['geo']:.2f}", r["pos"]] + [f"{v:.4f}" for v in p])
    print(f"\n저장: {path} (총 {(time.time() - t0) / 60:.1f}분)")


def cmd_final(args):
    ex, t1 = prep(args)
    t151.seed_all(ta.SEED)
    model = train_model(ex + t1, args.img)
    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    pt = MODEL_DIR / f"{args.name}.pt"
    torch.save(model.state_dict(), pt)
    model.eval()
    import onnx
    for score in args.export.split(","):
        p = MODEL_DIR / f"{args.name}_{score}.onnx"
        torch.onnx.export(Export(model, score), torch.randn(1, 3, args.img, args.img), p,
                          input_names=["input"], output_names=["output"], opset_version=12, dynamo=False)
        m = onnx.load(str(p))
        shp = [d.dim_value for d in m.graph.output[0].type.tensor_type.shape.dim]
        assert m.ir_version <= 8 and shp == [1, 1], (m.ir_version, shp)
        print(f"ONNX {p} ir={m.ir_version} opset={m.opset_import[0].version} out={shp} "
              f"sha256 {hashlib.sha256(p.read_bytes()).hexdigest()}", flush=True)


def cmd_baseline(args):
    """배포 T103 ONNX로 1,331장 전부 예측(기존 1,027장은 배포 모델이 학습한 사진 — 참고값)."""
    torch.set_num_threads(args.threads)
    ex, t1 = t151.load_all()
    items = ex + t1
    preds = t151.onnx_predict(t151.DEPLOYED_ONNX, items)
    t151.write_preds(OUT / "deployed_pred_all.csv", [(r, a, b) for r, (a, b) in zip(items, preds)])
    print(f"저장: {OUT / 'deployed_pred_all.csv'}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["cv", "final", "baseline"])
    ap.add_argument("name")
    ap.add_argument("--img", type=int, default=224)
    ap.add_argument("--t150w", type=float, default=2.0)
    ap.add_argument("--threads", type=int, default=2)
    ap.add_argument("--cons", type=float, default=0.0)
    ap.add_argument("--bigw", type=float, default=1.0)
    ap.add_argument("--big_deg", type=float, default=25.0)
    ap.add_argument("--rot", type=float, default=15.0)
    ap.add_argument("--crop", type=float, default=224 / 288)
    ap.add_argument("--export", default="reg,ord_sgn,ord_reg")
    a = ap.parse_args()
    {"cv": cmd_cv, "final": cmd_final, "baseline": cmd_baseline}[a.cmd](a)
