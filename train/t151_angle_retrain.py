"""T151: 각도 모델 재학습 비교 — '기존 데이터만'(0) vs '기존 + T150 304장'(1),
라벨은 기존 T103 가중(W) / 순수 기하(G) 두 가지(오케스트레이터 2026-10-29: 배포 후보는 G1).

`train_angle.py`(T103 CV 레시피)를 그대로 재사용한다. 바꾸는 것은 데이터뿐이다.
  - 기존 1,027장: `angle_labels_weighted_t103.csv`(배포 모델 sha 32c9d196과 같은 라벨),
    fold는 T103과 같은 규칙(세션 60초 + 근사중복)으로 만든다.
  - T150 304장(시범 49 + 본 255, status=ok): 순수 기하각. 앱 프레임(720x480 센서
    방향)이라 캐시에서 시계 90도 돌려 화면 방향으로 만든다(라벨 도구와 같음).
    묶음 = (폴더, 선택 때 episode) ∪ (폴더 안 60초 간격) ∪ 근사중복 — 묶음 통째로 한 fold.
  - 두 실험은 fold·시드가 같다. A의 fold k 모델은 T150 fold k도 예측한다(학습에 안 씀).

실행 (저장소 루트에서, 이미지는 메인 checkout에서 읽는다):
    python train/t151_angle_retrain.py cv W 0      # 가중 기존만 (T103 재현)
    python train/t151_angle_retrain.py cv W 1      # 가중 기존 + T150(기하)
    python train/t151_angle_retrain.py cv G 0      # 기하 기존만
    python train/t151_angle_retrain.py cv G 1      # 기하 기존 + T150 (배포 후보)
    python train/t151_angle_retrain.py baseline    # 배포 ONNX로 T150 예측
    python train/t151_angle_retrain.py report      # 표 -> train/t151/metrics.md
    python train/t151_angle_retrain.py final       # G1 전량 학습 + ONNX(model/, git 제외)
    python train/t151_angle_retrain.py bench       # 배포 vs 새 ONNX 입출력·추론 시간
환경변수 T151_DATA_ROOT (기본 C:/vibecoding/crossWalk) — image/, train/frames_* 위치.
"""

import csv
import hashlib
import os
import random
import sys
import time
from collections import defaultdict
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
from PIL import Image, ImageOps
from torch.utils.data import DataLoader

sys.path.insert(0, str(Path(__file__).resolve().parent))
import train_angle as ta  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
DATA_ROOT = Path(os.environ.get("T151_DATA_ROOT", "C:/vibecoding/crossWalk"))
OUT = REPO / "train" / "t151"
EXIST_CSV = REPO / "train" / "angle_labels_weighted_t103.csv"
T150_CSVS = [REPO / "train" / "angle_labels_t150_pilot.csv",
             REPO / "train" / "angle_labels_t150_main.csv"]
T150_META = [REPO / "train" / "t150_pilot50.csv", REPO / "train" / "t150_main413.csv"]
DEPLOYED_ONNX = REPO / "crosswalk_app" / "assets" / "model" / "crosswalk_angle.onnx"
NEW_PT = REPO / "model" / "crosswalk_angle_t151.pt"
NEW_ONNX = REPO / "model" / "crosswalk_angle_t151.onnx"

T150_GAP_MS = 60_000  # 기존 SESSION_GAP_SEC(60초)와 같은 간격

# 앱 단계(T146): |각도| <12 직진 / 12~20 / 20~30 / >=30 (히스테리시스는 프레임 단위라 제외)
LEVEL_EDGES = (12.0, 20.0, 30.0)
LEVEL_NAMES = ["직진<12", "12~20", "20~30", "≥30"]

# train_angle의 경로를 바꿔 끼운다(함수들은 호출 때 전역을 읽는다).
ta.DATA_DIR = DATA_ROOT / "image"
ta.LABEL_CSV = EXIST_CSV
ta.CACHE_DIR = REPO / "train" / "angle_cache"  # .gitignore 대상


def level(a):
    a = abs(a)
    return sum(a >= e for e in LEVEL_EDGES)


# ── 데이터 ───────────────────────────────────────────────────────────
def load_existing():
    items = ta.load_labeled_items()
    ta.assign_sessions(items)
    ta.dup_clusters(items)
    ta.split_folds(items)
    with open(EXIST_CSV, encoding="utf-8") as f:
        lab = {(r["class"], r["filename"]): r for r in csv.DictReader(f)}
    for r in items:
        L = lab[(r["cls"], r["file"])]
        r["src"] = "existing"
        r["frame"] = False
        r["wgt"] = float(L["angle_deg"])
        r["geo"] = float(L["geometric_deg"])  # == angle_labels.csv (1,027장 전부 일치 확인)
        r["pos"] = L["position"]
    return items


def load_t150():
    meta = {}
    for p in T150_META:
        with open(p, encoding="utf-8") as f:
            for r in csv.DictReader(f):
                meta[(r["folder"], r["filename"])] = r
    items = []
    for p in T150_CSVS:
        with open(p, encoding="utf-8") as f:
            for r in csv.DictReader(f):
                if r["status"] != "ok":
                    continue
                m = meta[(r["class"], r["filename"])]
                path = DATA_ROOT / "train" / r["class"] / r["filename"]
                if not path.exists():
                    raise RuntimeError(f"T150 사진 없음: {path}")
                items.append({
                    "path": str(path), "cls": r["class"], "file": r["filename"],
                    "angle": float(r["angle_deg"]), "src": "t150", "frame": True,
                    "geo": float(r["angle_deg"]), "wgt": float(r["angle_deg"]), "pos": "",
                    "t_ms": int(m["t_ms"]), "episode": int(m["episode"]),
                })
    keys = [(r["cls"], r["file"]) for r in items]
    assert len(keys) == len(set(keys)), "T150 시범/본 라벨에 중복 사진"
    return items


def group_t150(items):
    parent = {i: i for i in range(len(items))}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    by_folder = defaultdict(list)
    for i, r in enumerate(items):
        by_folder[r["cls"]].append(i)
    sig = {}
    for i, r in enumerate(items):
        im = Image.open(r["path"]).convert("L").resize((64, 64))
        sig[i] = np.asarray(im, dtype=np.float32)
    n_dup = 0
    for idx in by_folder.values():
        idx.sort(key=lambda i: items[i]["t_ms"])
        for a, b in zip(idx, idx[1:]):
            if items[b]["t_ms"] - items[a]["t_ms"] <= T150_GAP_MS:
                union(a, b)
        first = {}
        for i in idx:
            first.setdefault(items[i]["episode"], i)
            union(first[items[i]["episode"]], i)
        for x in range(len(idx)):
            for y in range(x + 1, len(idx)):
                if float(np.abs(sig[idx[x]] - sig[idx[y]]).mean()) < ta.DUP_PIXEL_THR:
                    if find(idx[x]) != find(idx[y]):
                        n_dup += 1
                    union(idx[x], idx[y])
    for i, r in enumerate(items):
        r["group"] = f"{r['cls']}#{find(i)}"
    return len({r["group"] for r in items}), n_dup


def split_t150(items):
    by_g = defaultdict(list)
    for r in items:
        by_g[r["group"]].append(r)
    load = [0] * ta.N_FOLDS
    for g in sorted(by_g, key=lambda g: (-len(by_g[g]), g)):
        k = min(range(ta.N_FOLDS), key=lambda k: load[k])
        for r in by_g[g]:
            r["fold"] = k
        load[k] += len(by_g[g])
    folds = defaultdict(set)
    for r in items:
        folds[r["group"]].add(r["fold"])
    assert all(len(f) == 1 for f in folds.values()), "T150 묶음이 여러 fold에 걸침"
    return load


def cache_path(r):
    return ta.CACHE_DIR / Path(r["path"]).parent.name / (Path(r["path"]).stem + ".png")


def build_cache(items):
    made = 0
    for r in items:
        dst = cache_path(r)
        if dst.exists():
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        im = ImageOps.exif_transpose(Image.open(r["path"])).convert("RGB")
        if r["frame"]:
            im = im.rotate(-90, expand=True)  # 센서 방향 -> 화면 방향(라벨 도구와 같음)
        im = im.resize((ta.CACHE_SIZE, ta.CACHE_SIZE), Image.BILINEAR)
        im.save(dst, format="PNG", optimize=False)
        made += 1
    print(f"[캐시] 신규 {made}장, 총 {len(items)}장", flush=True)


def load_all():
    ex = load_existing()
    t1 = load_t150()
    n_g, n_dup = group_t150(t1)
    load = split_t150(t1)
    print(f"T150 {len(t1)}장, 묶음 {n_g}개(근사중복으로 합친 것 {n_dup}), fold별 {load}")
    build_cache(ex + t1)
    return ex, t1


# ── 학습/예측 ────────────────────────────────────────────────────────
def seed_all(s):
    random.seed(s)
    np.random.seed(s)
    torch.manual_seed(s)


def train_model(tr, device):
    model = ta.build_model().to(device)
    loader = DataLoader(ta.AngleDataset(tr, train=True),
                        batch_size=ta.BATCH_SIZE, shuffle=True, num_workers=0)
    criterion = nn.SmoothL1Loss(beta=0.2)
    for p in model.features.parameters():
        p.requires_grad = False
    opt = optim.Adam(filter(lambda p: p.requires_grad, model.parameters()), lr=ta.LR_FROZEN)
    for e in range(ta.EPOCHS_FROZEN):
        loss = ta.run_epoch(model, loader, device, criterion, opt)
        print(f"  frozen  {e + 1}/{ta.EPOCHS_FROZEN} loss {loss:.4f}", flush=True)
    for p in model.parameters():
        p.requires_grad = True
    opt = optim.Adam(model.parameters(), lr=ta.LR_FINETUNE)
    sched = optim.lr_scheduler.CosineAnnealingLR(opt, T_max=ta.EPOCHS_FINETUNE)
    for e in range(ta.EPOCHS_FINETUNE):
        loss = ta.run_epoch(model, loader, device, criterion, opt)
        sched.step()
        print(f"  finetune {e + 1}/{ta.EPOCHS_FINETUNE} loss {loss:.4f}", flush=True)
    return model


def predict_both(model, items, device):
    """(좌우반전 TTA 예측, 단일 예측) — 앱은 TTA 없이 한 번만 돌린다."""
    model.eval()
    loader = DataLoader(ta.AngleDataset(items, train=False),
                        batch_size=ta.BATCH_SIZE, shuffle=False, num_workers=0)
    tta, plain = [], []
    with torch.no_grad():
        for x, _ in loader:
            x = x.to(device)
            a = model(x).cpu().numpy().ravel()
            b = -model(torch.flip(x, dims=[3])).cpu().numpy().ravel()
            tta += ((a + b) / 2 * ta.ANGLE_SCALE).tolist()
            plain += (a * ta.ANGLE_SCALE).tolist()
    return tta, plain


# AngleDataset이 캐시 경로를 r["path"]로 계산하므로 T150도 같은 규칙(부모 폴더명/stem.png)이면 된다.
assert ta.cache_path(Path("x/frames_1025/f_1.jpg")).parts[-2:] == ("frames_1025", "f_1.png")


def write_preds(path, rows):
    with open(path, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["src", "class", "filename", "fold", "group", "geo_deg", "wgt_deg",
                    "pos", "pred_tta", "pred_plain"])
        for r, a, b in rows:
            w.writerow([r["src"], r["cls"], r["file"], r["fold"], r.get("group", r.get("session")),
                        f"{r['geo']:.2f}", f"{r['wgt']:.2f}", r["pos"], f"{a:.2f}", f"{b:.2f}"])


def set_target(items, labelset):
    """W = 기존 T103 가중 라벨, G = 순수 기하(angle_labels.csv). T150은 둘 다 기하각."""
    for r in items:
        r["angle"] = r["wgt"] if labelset == "W" else r["geo"]


def cmd_cv(labelset, arm):
    OUT.mkdir(parents=True, exist_ok=True)
    ex, t1 = load_all()
    set_target(ex + t1, labelset)
    run = f"{labelset}{arm}"
    device = torch.device("cpu")
    rows = []
    t0 = time.time()
    for k in range(ta.N_FOLDS):
        seed_all(ta.SEED + k)
        tr = [r for r in ex if r["fold"] != k]
        if arm == "1":
            tr += [r for r in t1 if r["fold"] != k]
        te = [r for r in ex if r["fold"] == k] + [r for r in t1 if r["fold"] == k]
        print(f"\n[{run} fold {k}] train {len(tr)} / test {len(te)} "
              f"(경과 {(time.time() - t0) / 60:.1f}분)", flush=True)
        model = train_model(tr, device)
        tta, plain = predict_both(model, te, device)
        rows += list(zip(te, tta, plain))
        e_ex = [abs(a - r["angle"]) for r, a, _ in zip(te, tta, plain) if r["src"] == "existing"]
        e_t = [abs(a - r["angle"]) for r, a, _ in zip(te, tta, plain) if r["src"] == "t150"]
        print(f"  -> fold {k} 기존 {np.mean(e_ex):.1f}도 / T150 {np.mean(e_t):.1f}도", flush=True)
    write_preds(OUT / f"cv_pred_{run}.csv", rows)
    print(f"\n저장: {OUT / f'cv_pred_{run}.csv'} (총 {(time.time() - t0) / 60:.1f}분)")


# ── ONNX 추론 (앱과 같은 입력: 화면 방향 288 정사각 -> 중앙 224, 정규화) ──
def onnx_input(r):
    im = Image.open(cache_path(r)).convert("RGB")
    off = (ta.CACHE_SIZE - ta.IMG_SIZE) // 2
    im = im.crop((off, off, off + ta.IMG_SIZE, off + ta.IMG_SIZE))
    x = np.asarray(im, dtype=np.float32) / 255.0
    x = (x - np.array(ta.NORM_MEAN, np.float32)) / np.array(ta.NORM_STD, np.float32)
    return x.transpose(2, 0, 1)[None]


def onnx_predict(path, items):
    import onnxruntime as ort
    s = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
    name = s.get_inputs()[0].name
    out = []
    for r in items:
        x = onnx_input(r)
        a = float(s.run(None, {name: x})[0].ravel()[0])
        b = -float(s.run(None, {name: x[:, :, :, ::-1].copy()})[0].ravel()[0])
        out.append(((a + b) / 2 * ta.ANGLE_SCALE, a * ta.ANGLE_SCALE))
    return out


def cmd_baseline():
    OUT.mkdir(parents=True, exist_ok=True)
    ex, t1 = load_all()
    preds = onnx_predict(DEPLOYED_ONNX, t1)
    write_preds(OUT / "deployed_pred_t150.csv", [(r, a, b) for r, (a, b) in zip(t1, preds)])
    print(f"배포 모델 sha {hashlib.sha256(DEPLOYED_ONNX.read_bytes()).hexdigest()[:12]} "
          f"-> {OUT / 'deployed_pred_t150.csv'}")


# ── 지표 ─────────────────────────────────────────────────────────────
def read_preds(path, truth="geo"):
    with open(path, encoding="utf-8") as f:
        return [{**r, "gt": float(r[f"{truth}_deg"]), "tta": float(r["pred_tta"]),
                 "plain": float(r["pred_plain"])} for r in csv.DictReader(f)]


def metrics(rows, key):
    gt = np.array([r["gt"] for r in rows])
    pr = np.array([r[key] for r in rows])
    err = np.abs(pr - gt)
    m = {"n": len(rows), "mae": err.mean(), "bands": []}
    for lo, hi in [(0, 12), (12, 20), (20, 30), (30, 999)]:
        sel = (np.abs(gt) >= lo) & (np.abs(gt) < hi)
        m["bands"].append((int(sel.sum()), err[sel].mean() if sel.any() else float("nan"),
                           (pr[sel] - gt[sel]).__abs__().mean() if sel.any() else float("nan"),
                           (np.abs(pr[sel]) - np.abs(gt[sel])).mean() if sel.any() else float("nan")))
    lg = np.array([level(a) for a in gt])
    lp = np.array([level(a) for a in pr])
    cm = np.zeros((4, 4), int)
    for a, b in zip(lg, lp):
        cm[a, b] += 1
    m["cm"] = cm
    big = lg == 3
    m["big_n"] = int(big.sum())
    m["big_to_mid"] = int((big & ((lp == 1) | (lp == 2))).sum())
    m["big_to_straight"] = int((big & (lp == 0)).sum())
    dev = (lg >= 1) & (lp >= 1)
    m["sign_wrong"] = (int((dev & (np.sign(gt) != np.sign(pr))).sum()), int(dev.sum()))
    return m


def fmt_metrics(title, m):
    L = [f"#### {title} (n={m['n']}, 전체 MAE {m['mae']:.1f}°)", "",
         "| 정답 크기 구간 | n | MAE | 평균(예측 크기 − 정답 크기) |", "|---|---|---|---|"]
    for name, (n, mae, _, bias) in zip(["0~12", "12~20", "20~30", "30+"], m["bands"]):
        L.append(f"| {name} | {n} | {mae:.1f} | {bias:+.1f} |")
    L += ["", "혼동표 (행=정답 단계, 열=예측 단계)", "",
          "| 정답＼예측 | " + " | ".join(LEVEL_NAMES) + " | 재현 |",
          "|---" * 6 + "|"]
    cm = m["cm"]
    for i in range(4):
        rec = cm[i, i] / cm[i].sum() * 100 if cm[i].sum() else float("nan")
        L.append(f"| {LEVEL_NAMES[i]} | " + " | ".join(str(v) for v in cm[i]) + f" | {rec:.0f}% |")
    prec = [cm[j, j] / cm[:, j].sum() * 100 if cm[:, j].sum() else float("nan") for j in range(4)]
    L.append("| 정밀 | " + " | ".join(f"{p:.0f}%" for p in prec) + " | |")
    bn = m["big_n"]
    L += ["", f"- 큰 이탈(≥30) {bn}장 → 중간(12~30) {m['big_to_mid']}장"
          f" ({m['big_to_mid'] / bn * 100 if bn else float('nan'):.0f}%), 직진 {m['big_to_straight']}장",
          f"- 방향 반대(정답·예측 모두 ≥12 중): {m['sign_wrong'][0]}/{m['sign_wrong'][1]}", ""]
    return "\n".join(L)


def summary_row(name, m):
    b = m["bands"]
    bn = m["big_n"]
    cm = m["cm"]
    rec = [cm[i, i] / cm[i].sum() * 100 if cm[i].sum() else float("nan") for i in range(4)]
    return (f"| {name} | {m['n']} | {m['mae']:.1f} | " + " | ".join(f"{x[1]:.1f}" for x in b)
            + " | " + " | ".join(f"{x:.0f}%" for x in rec)
            + f" | {m['big_to_mid'] / bn * 100 if bn else float('nan'):.0f}% |")


RUNS = [("W0", "W0 가중 기존만 (T103 재현)"), ("W1", "W1 가중 기존 + T150"),
        ("G0", "G0 기하 기존만"), ("G1", "G1 기하 기존 + T150 (배포 후보)")]


def subset(rows, name):
    """기존 사진을 위치 라벨로 나눈다: 끝(|위치|=2) / 끝 아님(위치 -1~1) / 위치 없음."""
    if name == "t150":
        return [r for r in rows if r["src"] == "t150"]
    ex = [r for r in rows if r["src"] == "existing"]
    if name == "existing":
        return ex
    if name == "edge":
        return [r for r in ex if r["pos"] in ("2", "-2")]
    if name == "nonedge":
        return [r for r in ex if r["pos"] in ("-1", "0", "1")]
    if name == "nopos":
        return [r for r in ex if r["pos"] == ""]
    raise ValueError(name)


def cmd_report():
    runs = {k: read_preds(OUT / f"cv_pred_{k}.csv") for k, _ in RUNS
            if (OUT / f"cv_pred_{k}.csv").exists()}
    runs_w = {k: read_preds(OUT / f"cv_pred_{k}.csv", "wgt") for k in runs}
    D = read_preds(OUT / "deployed_pred_t150.csv")
    names = dict(RUNS)
    L = ["# T151 지표 (자동 생성: `python train/t151_angle_retrain.py report`)", "",
         "모든 표의 정답은 **순수 기하각**(기존 `angle_labels.csv` = 가중 파일의 geometric_deg, "
         "T150 라벨)이다. 따로 적은 곳만 가중 정답.", ""]
    hdr = ("| 모델 | n | MAE | 0~12 | 12~20 | 20~30 | 30+ | 재현 직진 | 재현 12~20 | "
           "재현 20~30 | 재현 ≥30 | 큰→중간 |")
    sep = "|---" * 12 + "|"
    for key, kname in [("plain", "단일 추론 (앱과 같음)"), ("tta", "좌우반전 TTA (T103 CV 로그와 같은 방식)")]:
        L += [f"## 요약 — {kname}", "", "### T150 304장", "", hdr, sep,
              summary_row("배포 T103 (32c9d196)", metrics(D, key))]
        for k in runs:
            L.append(summary_row(names[k], metrics(subset(runs[k], "t150"), key)))
        for sub, title in [("existing", "기존 1,027장 전체"),
                           ("nonedge", "기존 · 위치 라벨 있음, 끝 아님(|위치|≤1)"),
                           ("edge", "기존 · 끝 장면(|위치|=2, 가중이 바꾼 장면 대부분)"),
                           ("nopos", "기존 · 위치 라벨 없음")]:
            L += ["", f"### {title}", "", hdr, sep]
            for k in runs:
                L.append(summary_row(names[k], metrics(subset(runs[k], sub), key)))
        L.append("")
    # 가중 편향: 끝 장면에서 예측이 기하각보다 얼마나 밀려 있나
    L += ["## 끝 장면 편향 (단일 추론) — 기존 |위치|=2", "",
          "| 모델 | n | MAE(기하 정답) | MAE(가중 정답) | 평균(예측−기하) | 평균(예측 크기 − 기하 크기) |",
          "|---|---|---|---|---|---|"]
    for k in runs:
        e = subset(runs[k], "edge")
        ew = subset(runs_w[k], "edge")
        L.append(f"| {names[k]} | {len(e)} | "
                 f"{np.mean([abs(r['plain'] - r['gt']) for r in e]):.1f} | "
                 f"{np.mean([abs(r['plain'] - r['gt']) for r in ew]):.1f} | "
                 f"{np.mean([r['plain'] - r['gt'] for r in e]):+.1f} | "
                 f"{np.mean([abs(r['plain']) - abs(r['gt']) for r in e]):+.1f} |")
    L += ["", "## 참고 — 기존 1,027장을 가중 정답으로 (T103 CV 로그 8.6°와 비교용, TTA)", "",
          hdr, sep]
    for k in runs:
        L.append(summary_row(names[k], metrics(subset(runs_w[k], "existing"), "tta")))
    L += ["", "## 상세 — 단일 추론 (앱과 같음)", ""]
    L.append(fmt_metrics("T150 · 배포 T103", metrics(D, "plain")))
    for k in runs:
        L.append(fmt_metrics(f"T150 · {names[k]}", metrics(subset(runs[k], "t150"), "plain")))
    for k in runs:
        L.append(fmt_metrics(f"기존 · {names[k]}", metrics(subset(runs[k], "existing"), "plain")))
    L += ["## fold별 T150 MAE (단일 추론)", "",
          "| fold | n | 배포 | " + " | ".join(runs) + " |", "|---" * (3 + len(runs)) + "|"]
    mae = lambda rs: np.mean([abs(r["plain"] - r["gt"]) for r in rs])
    for k in range(ta.N_FOLDS):
        ds = [r for r in D if int(r["fold"]) == k]
        L.append(f"| {k} | {len(ds)} | {mae(ds):.1f} | " + " | ".join(
            f"{mae([r for r in subset(runs[x], 't150') if int(r['fold']) == k]):.1f}"
            for x in runs) + " |")
    # 묶음 부트스트랩: 같은 사진에서 두 모델 오차 차이 — 묶음(T150 group / 기존 session)을 재표집
    L += ["", "## MAE 차이의 묶음 부트스트랩 (단일 추론, 2,000회, 95% 구간)", "",
          "음수 = 뒤 모델이 더 정확. 묶음 = T150 (폴더, episode, 60초) / 기존 세션.", "",
          "| 비교 | 대상 | 차이 | 95% 구간 | 묶음 수 |", "|---|---|---|---|---|"]
    pairs = [("G0", "G1"), ("W0", "W1"), ("W1", "G1"), ("W0", "G0")]
    D_by = {(r["class"], r["filename"]): r for r in D}
    for sub in ("t150", "existing"):
        cand = [("배포", "G1"), ("배포", "W1")] if sub == "t150" else []
        for a, b in cand + pairs:
            if b not in runs or (a != "배포" and a not in runs):
                continue
            rb = {(r["class"], r["filename"]): r for r in subset(runs[b], sub)}
            ra = D_by if a == "배포" else {(r["class"], r["filename"]): r
                                           for r in subset(runs[a], sub)}
            grp = defaultdict(list)
            for key, r in rb.items():
                grp[r["group"]].append(abs(r["plain"] - r["gt"]) - abs(ra[key]["plain"] - r["gt"]))
            gs = list(grp.values())
            rng = np.random.default_rng(0)
            boot = []
            for _ in range(2000):
                pick = rng.integers(0, len(gs), len(gs))
                v = np.concatenate([gs[i] for i in pick])
                boot.append(v.mean())
            d = np.mean(np.concatenate(gs))
            lo, hi = np.percentile(boot, [2.5, 97.5])
            an = "배포 T103" if a == "배포" else a
            L.append(f"| {an} → {b} | {sub} | {d:+.2f}° | [{lo:+.2f}, {hi:+.2f}] | {len(gs)} |")
    (OUT / "metrics.md").write_text("\n".join(L) + "\n", encoding="utf-8")
    print("\n".join(L))


# ── 배포 후보 ────────────────────────────────────────────────────────
def cmd_final():
    ex, t1 = load_all()
    set_target(ex + t1, "G")  # 배포 후보 = 순수 기하 (오케스트레이터 2026-10-29)
    seed_all(ta.SEED)
    model = train_model(ex + t1, torch.device("cpu"))
    NEW_PT.parent.mkdir(parents=True, exist_ok=True)
    torch.save(model.state_dict(), NEW_PT)
    model.eval().cpu()
    torch.onnx.export(model, torch.randn(1, 3, ta.IMG_SIZE, ta.IMG_SIZE), NEW_ONNX,
                      input_names=["input"], output_names=["output"],
                      opset_version=12, dynamo=False)
    import onnx
    m = onnx.load(str(NEW_ONNX))
    out_shape = [d.dim_value for d in m.graph.output[0].type.tensor_type.shape.dim]
    assert m.ir_version <= 8, f"IR {m.ir_version} — 모바일 비호환"
    assert out_shape[-1] == 1, f"출력 차원이 1이 아님: {out_shape}"
    print(f"ONNX {NEW_ONNX} ir={m.ir_version} opset={m.opset_import[0].version} "
          f"sha256 {hashlib.sha256(NEW_ONNX.read_bytes()).hexdigest()}")


def cmd_bench():
    import onnx
    import onnxruntime as ort
    ex, t1 = load_all()
    for p in (DEPLOYED_ONNX, NEW_ONNX):
        m = onnx.load(str(p))
        io = [(v.name, [d.dim_value or d.dim_param for d in v.type.tensor_type.shape.dim])
              for v in list(m.graph.input) + list(m.graph.output)]
        so = ort.SessionOptions()
        so.intra_op_num_threads = 1
        s = ort.InferenceSession(str(p), so, providers=["CPUExecutionProvider"])
        x = onnx_input(t1[0])
        for _ in range(20):
            s.run(None, {"input": x})
        ts = []
        for _ in range(200):
            t = time.perf_counter()
            s.run(None, {"input": x})
            ts.append((time.perf_counter() - t) * 1000)
        print(f"{p.name}: size {p.stat().st_size / 1e6:.2f}MB ir={m.ir_version} "
              f"opset={m.opset_import[0].version} io={io} "
              f"1스레드 중앙값 {np.median(ts):.2f}ms (p90 {np.percentile(ts, 90):.2f})")
    # 새 ONNX가 학습 pt와 같은 값을 내는지(내보내기 검증) — T150 앞 20장
    model = ta.build_model()
    model.load_state_dict(torch.load(NEW_PT, map_location="cpu"))
    model.eval()
    s = ort.InferenceSession(str(NEW_ONNX), providers=["CPUExecutionProvider"])
    d = []
    for r in t1[:20]:
        x = onnx_input(r)
        with torch.no_grad():
            a = float(model(torch.from_numpy(x))[0, 0])
        d.append(abs(a - float(s.run(None, {"input": x})[0].ravel()[0])) * ta.ANGLE_SCALE)
    print(f"pt vs onnx 최대 차이 {max(d):.4f}도 (20장)")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "cv":
        cmd_cv(sys.argv[2], sys.argv[3])
    elif cmd == "baseline":
        cmd_baseline()
    elif cmd == "report":
        cmd_report()
    elif cmd == "final":
        cmd_final()
    elif cmd == "bench":
        cmd_bench()
    else:
        print(__doc__)
