"""T200: 실기기 프레임에서 노면 모델(앱과 같은 ONNX·전처리)의 횡단보도(3) 비율을 세어
시안에 쓸 프레임 후보를 고른다. 출력: train/t200/scan.csv (프레임 이미지는 커밋하지 않는다).
실행(저장소/워크트리 루트): PYTHONIOENCODING=utf-8 python train/t200/scan.py [프레임 폴더 ...]
"""
import csv, sys
from pathlib import Path
import cv2, numpy as np, onnxruntime as ort

ROOT = Path(__file__).resolve().parents[2]
MODEL = ROOT / "crosswalk_app/assets/model/crosswalk_surface.onnx"
DATA = Path("C:/vibecoding/crossWalk/train")
MEAN = np.array([0.485, 0.456, 0.406], np.float32); STD = np.array([0.229, 0.224, 0.225], np.float32)
CW = 3

def load_upright(p):
    # 기존 프레임은 센서 방향(가로) — t148과 같이 시계방향 90도로 세운다.
    return cv2.rotate(cv2.imdecode(np.fromfile(str(p), np.uint8), 1), cv2.ROTATE_90_CLOCKWISE)

def seg(sess, bgr):
    """앱과 같다: 세로 프레임 전체를 224x224로 누르고 ImageNet 정규화 → argmax [224,224]."""
    rgb = cv2.cvtColor(cv2.resize(bgr, (224, 224), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2RGB)
    x = ((rgb / 255.0 - MEAN) / STD).transpose(2, 0, 1)[None].astype(np.float32)
    return sess.run(None, {"input": x})[0][0].argmax(0)

if __name__ == "__main__":
    dirs = sys.argv[1:] or ["frames_1122", "frames_1118", "frames_1112", "frames_1110"]
    sess = ort.InferenceSession(str(MODEL), providers=["CPUExecutionProvider"])
    rows = []
    for d in dirs:
        for p in sorted((DATA / d).glob("*.jpg"))[::8]:
            m = seg(sess, load_upright(p)) == CW
            r = m.mean()
            ys, xs = np.nonzero(m[112:])  # 아래 절반 — 발 앞
            cx = (xs.mean() / 224 - 0.5) if len(xs) else float("nan")
            rows.append([d, p.name, round(float(r), 3), round(float(m[112:].mean()), 3), round(float(cx), 3)])
    out = Path(__file__).with_name("scan.csv")
    with open(out, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f); w.writerow(["dir", "file", "cw_all", "cw_bottom", "cx_bottom"]); w.writerows(rows)
    print(len(rows), "rows ->", out)
