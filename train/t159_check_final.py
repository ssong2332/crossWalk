"""T159: 최종 ONNX 점검 — (1) PyTorch 최종 모델과 같은 값인지 (2) CV 예측과 얼마나 가까운지 (3) PC 1스레드 시간.

전처리(앱에 넘길 명세와 같음): EXIF 회전 → (앱 프레임이면 -90도 회전 = 화면 세로) → 화면 전체를
224×224로 BILINEAR 축소(크롭 없음, cropRatio 1.0) → RGB /255 → ImageNet 평균·표준편차 정규화 → NCHW.
    python train/t159_check_final.py fullbw224 [장수=60]
"""
import csv
import sys
import time
from pathlib import Path

import numpy as np
import onnxruntime as ort
import torch
from PIL import Image, ImageOps

sys.path.insert(0, str(Path(__file__).resolve().parent))
import t159_train as tt  # noqa: E402
import t159_export_tta as ex  # noqa: E402
import train_angle as ta  # noqa: E402
import t151_angle_retrain as t151  # noqa: E402

DATA = Path("C:/vibecoding/crossWalk")
name = sys.argv[1]
N = int(sys.argv[2]) if len(sys.argv) > 2 else 60


def prep(src, cls, fn):
    p = DATA / ("image" if src == "existing" else "train") / cls / fn
    im = ImageOps.exif_transpose(Image.open(p)).convert("RGB")
    if src == "t150":
        im = im.rotate(-90, expand=True)
    im = im.resize((224, 224), Image.BILINEAR)
    a = (np.asarray(im, np.float32) / 255 - ta.NORM_MEAN) / ta.NORM_STD
    return a.transpose(2, 0, 1)[None].astype(np.float32)


rows = list(csv.DictReader(open(tt.OUT / f"cv_pred_{name}.csv", encoding="utf-8")))
rng = np.random.default_rng(0)
t150 = [r for r in rows if r["src"] == "t150"]
exi = [r for r in rows if r["src"] == "existing"]
pick = [t150[i] for i in rng.choice(len(t150), N * 2 // 3, replace=False)] + \
       [exi[i] for i in rng.choice(len(exi), N - N * 2 // 3, replace=False)]

so = ort.SessionOptions()
so.intra_op_num_threads = 1
so.inter_op_num_threads = 1
sess = ort.InferenceSession(str(tt.MODEL_DIR / f"{name}_ord_reg_tta.onnx"), so, providers=["CPUExecutionProvider"])
head = tt.Head(224)
head.load_state_dict(torch.load(tt.MODEL_DIR / f"{name}.pt", map_location="cpu"))
head.eval()
wrap = ex.ExportTTA(head).eval()

on, pt, cvs, gts, srcs = [], [], [], [], []
for r in pick:
    x = prep(r["src"], r["class"], r["filename"])
    on.append(float(sess.run(None, {"input": x})[0][0, 0]) * 90)
    with torch.no_grad():
        pt.append(float(wrap(torch.from_numpy(x))[0, 0]) * 90)
    reg = (float(r["reg_plain"]) + float(r["reg_flip"])) / 2
    cvs.append(np.sign(reg) * (float(r["ord_plain"]) + float(r["ord_flip"])) / 2)
    gts.append(float(r["geo_deg"]))
    srcs.append(r["src"])
on, pt, cvs, gts = map(np.array, (on, pt, cvs, gts))
lv = lambda a: np.digitize(np.abs(a), [8.5, 29.0])
print(f"[1] ONNX vs PyTorch 최종: 최대 차 {np.abs(on - pt).max():.5f}도 ({len(on)}장)")
print(f"[2] ONNX(최종) vs CV(그 사진을 안 본 fold 모델): 평균 |차| {np.abs(on - cvs).mean():.2f}도, "
      f"부호 일치 {np.mean(np.sign(on) == np.sign(cvs)) * 100:.0f}%, 단계(8.5/29) 일치 {np.mean(lv(on) == lv(cvs)) * 100:.0f}%")
print(f"    참고: |ONNX − 정답| 평균 {np.abs(on - gts).mean():.2f}도 (최종 모델은 이 사진을 학습함 — 낙관값), "
      f"|CV − 정답| 평균 {np.abs(cvs - gts).mean():.2f}도")
for i in range(min(5, len(pick))):
    print(f"    예: {pick[i]['class']}/{pick[i]['filename']} 정답 {gts[i]:+.1f} 최종 {on[i]:+.1f} CV {cvs[i]:+.1f}")


def bench(path, reps=300):
    s = ort.InferenceSession(str(path), so, providers=["CPUExecutionProvider"])
    x = np.random.default_rng(1).standard_normal((1, 3, 224, 224)).astype(np.float32)
    for _ in range(30):
        s.run(None, {"input": x})
    t = []
    for _ in range(reps):
        a = time.perf_counter()
        s.run(None, {"input": x})
        t.append((time.perf_counter() - a) * 1000)
    return float(np.median(t))


print("[3] PC 1스레드 중앙값(ms, 300회):")
for lab, p in [("배포 T103", t151.DEPLOYED_ONNX), (f"{name}_ord_reg (1회)", tt.MODEL_DIR / f"{name}_ord_reg.onnx"),
               (f"{name}_ord_reg_tta (반전 포함 1파일)", tt.MODEL_DIR / f"{name}_ord_reg_tta.onnx")]:
    print(f"    {lab}: {bench(p):.2f}")
