"""배포 ONNX 3종(분류기·각도·위치)을 사진에 돌린다. 전처리는 screenshot_probe_0908.py와 동일,
위치는 cropRatio 1.0(position_estimator.dart:77)."""
import sys
from pathlib import Path
import numpy as np, onnxruntime as ort
from PIL import Image, ImageOps
A = Path(r"C:\vibecoding\crossWalk\crosswalk_app\assets\model")
LABELS = ["none", "approach", "front", "left", "right"]
MEAN = np.array([0.485, 0.456, 0.406], np.float32); STD = np.array([0.229, 0.224, 0.225], np.float32)
IMG, GRID = 224, 3
def norm(a): return ((a / 255.0 - MEAN) / STD).transpose(2, 0, 1)[None].astype(np.float32)
def cls_t(p): return norm(np.asarray(Image.open(p).convert("RGB").resize((IMG, IMG), Image.BOX), np.float32))
def reg_t(p, crop):
    arr = np.asarray(ImageOps.exif_transpose(Image.open(p)).convert("RGB"), np.float32)
    dh, dw = arr.shape[:2]; cw, ch = int(dw * crop), int(dh * crop)
    ox, oy = (dw - cw) // 2, (dh - ch) // 2
    ys = oy + (np.arange(IMG * GRID) * ch) // (IMG * GRID); xs = ox + (np.arange(IMG * GRID) * cw) // (IMG * GRID)
    return norm(arr[np.ix_(ys, xs)].reshape(IMG, GRID, IMG, GRID, 3).mean(axis=(1, 3)))
S = {k: ort.InferenceSession(str(A / f), providers=["CPUExecutionProvider"]) for k, f in
     [("c", "crosswalk_model.onnx"), ("a", "crosswalk_angle.onnx"), ("p", "crosswalk_position.onnx")]}
def run(k, x): s = S[k]; return np.asarray(s.run(None, {s.get_inputs()[0].name: x})[0]).ravel()
def infer(p):
    lg = run("c", cls_t(p)); e = np.exp(lg - lg.max()); pr = e / e.sum()
    return pr, float(run("a", reg_t(p, 224 / 288))[0]) * 90.0, float(run("p", reg_t(p, 1.0))[0]) * 2.0
if __name__ == "__main__":
    for p in sys.argv[1:]:
        pr, a, pos = infer(p)
        print(Path(p).name, " ".join(f"{l}={v:.2f}" for l, v in zip(LABELS, pr)), f"angle={a:+.1f} pos={pos:+.2f}")
