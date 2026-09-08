"""2026-09-08 사용자 실기기 스크린샷 5장 검증 (T83 진단).

사용자 보고 4가지:
  1. 노트북 화면을 통해 테스트했다 (매체 요인)
  2. 왼쪽 이탈인데 직진으로 판단한다
  3. 가끔 화살표 디자인이 초기 버전(평면 화살표)으로 나온다
  4. 각도가 내가 지정한 값과 다르다

스크린샷 상단에 원본 파일명이 찍혀 있어 정답 라벨과 직접 대조할 수 있다.
5장 중 저해상도로 판독 가능한 것은 2장뿐이므로(나머지 3장은 파일명을 확정
못 했다) 개별 대조는 2장만 하고, 나머지는 전체 집계로 본다.

전처리는 배포 앱과 동일 경로다 (state_angle_consistency.py와 같은 함수):
  분류기 = EXIF 회전 미적용 + BOX(=Interpolation.average) 224
  각도   = EXIF 회전 적용 + 중앙 224/288 크롭 + 3x3 평균

한계: 원본 직접 추론은 **학습 데이터**라 낙관적이다. 그래서 "원본에서도
틀린다"는 강한 근거지만, "원본에서 맞는다"는 모델이 외웠을 뿐일 수 있어
매체 탓으로 곧장 결론지을 수 없다. 그 구분은 누수 없는 CV 예측으로 본다.
"""
import csv
import json
from collections import Counter
from pathlib import Path

import numpy as np
import onnxruntime as ort
from PIL import Image, ImageOps

REPO = Path(__file__).resolve().parent.parent
ASSETS = REPO / "crosswalk_app" / "assets" / "model"
IMAGE_ROOT = REPO / "image"
CV_JSON = REPO / "train" / "groupkfold_5class_out" / "all_probs.json"

CLASS_DIRS = ["0_none", "1_approach", "2_front", "3_left", "4_right"]
LABELS = ["none", "approach", "front", "left", "right"]
# classifier.dart:49,81,82,100 — approach는 T79에서 0.40 -> 0.55로 올렸다.
THRESHOLDS = {"front": 0.40, "none": 0.40, "approach": 0.55,
              "left": 0.55, "right": 0.55}

IMG, CROP_RATIO, GRID, ANGLE_SCALE = 224, 224.0 / 288.0, 3, 90.0
MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)

# camera_screen.dart:1320 (T79)
MIN_DEV_ANGLE = 5.0

# 스크린샷에서 전사한 값 (파일명을 확정한 2장만)
SCREENSHOTS = [
    # (파일명, 화면표시 상태, 화면표시 보정, 화면표시 원시, 화살표 모양)
    ("20260708_203311.jpg", "front", 5, 6, "지면(3D)"),
    ("20260709_201946.jpg", "right", 17, 22, "평면(초기버전)"),
]


def cls_tensor(path):
    im = Image.open(path).convert("RGB").resize((IMG, IMG), Image.BOX)
    a = np.asarray(im, dtype=np.float32) / 255.0
    return ((a - MEAN) / STD).transpose(2, 0, 1)[None].astype(np.float32)


def angle_tensor(path):
    arr = np.asarray(ImageOps.exif_transpose(Image.open(path)).convert("RGB"),
                     dtype=np.float32)
    dh, dw = arr.shape[0], arr.shape[1]
    cw, ch = int(dw * CROP_RATIO), int(dh * CROP_RATIO)
    ox, oy = (dw - cw) // 2, (dh - ch) // 2
    ys = oy + (np.arange(IMG * GRID) * ch) // (IMG * GRID)
    xs = ox + (np.arange(IMG * GRID) * cw) // (IMG * GRID)
    sub = arr[np.ix_(ys, xs)].reshape(IMG, GRID, IMG, GRID, 3).mean(axis=(1, 3))
    a = sub / 255.0
    return ((a - MEAN) / STD).transpose(2, 0, 1)[None].astype(np.float32)


def softmax(x):
    e = np.exp(x - x.max())
    return e / e.sum()


def decide(probs):
    i = int(np.argmax(probs))
    lab, conf = LABELS[i], float(probs[i])
    return ("무판정" if conf < THRESHOLDS[lab] else lab), conf


def agrees(state, angle):
    """camera_screen.dart의 _angleAgreesWithState 재현 (T79)."""
    if angle is None:
        return False
    if state == "left":
        return angle >= MIN_DEV_ANGLE
    if state == "right":
        return angle <= -MIN_DEV_ANGLE
    return state == "front"


def main():
    cls_sess = ort.InferenceSession(
        str(ASSETS / "crosswalk_model.onnx"), providers=["CPUExecutionProvider"])
    ang_sess = ort.InferenceSession(
        str(ASSETS / "crosswalk_angle.onnx"), providers=["CPUExecutionProvider"])
    cin, ain = cls_sess.get_inputs()[0].name, ang_sess.get_inputs()[0].name

    def infer(path):
        probs = softmax(np.asarray(cls_sess.run(None, {cin: cls_tensor(path)})[0][0]))
        state, conf = decide(probs)
        ang = float(np.asarray(
            ang_sess.run(None, {ain: angle_tensor(path)})[0]).ravel()[0]) * ANGLE_SCALE
        return state, conf, ang, probs

    # 라벨: v3 순수기하 / 위험가중
    geo, wgt = {}, {}
    for r in csv.DictReader(open(REPO / "train/angle_labels.csv", encoding="utf-8")):
        if r["status"] == "ok":
            geo[r["filename"]] = (r["class"], float(r["angle_deg"]))
    for r in csv.DictReader(
            open(REPO / "train/angle_labels_weighted.csv", encoding="utf-8")):
        wgt[r["filename"]] = float(r["angle_deg"])

    cv = {r["file"]: r for r in json.load(open(CV_JSON, encoding="utf-8"))}

    print("=" * 78)
    print("(1) 스크린샷 개별 대조 — 파일명을 확정한 2장")
    print("=" * 78)
    for name, shown_state, shown_sm, shown_raw, arrow in SCREENSHOTS:
        cdir = next(d for d in CLASS_DIRS if (IMAGE_ROOT / d / name).exists())
        truth = LABELS[CLASS_DIRS.index(cdir)]
        state, conf, ang, _ = infer(IMAGE_ROOT / cdir / name)
        c = cv.get(name)
        cvpred = max(c["probs"], key=c["probs"].get) if c else "?"
        g = geo.get(name)
        print(f"\n{name}  정답={truth}")
        print(f"  화면표시 : {shown_state}, 보정 {shown_sm} (원시 {shown_raw}), "
              f"화살표 {arrow}")
        print(f"  원본직접 : {state} (확신 {conf:.3f}), 각도 {ang:+.1f}도")
        print(f"  누수없는CV: {cvpred}")
        if g:
            print(f"  사람 라벨 : 기하 {g[1]:+.1f}도 / 가중 {wgt.get(name, float('nan')):+.1f}도")
        print(f"  T79 일치? : 원본 {agrees(state, ang)} / "
              f"화면 {agrees(shown_state, float(shown_raw))} "
              f"-> False면 평면 화살표로 되돌아간다")

    print()
    print("=" * 78)
    print("(2) 항목2 — 왼쪽 이탈이 무엇으로 판정되는가 (원본 직접 / 누수없는CV)")
    print("=" * 78)
    for cdir in ("3_left", "4_right"):
        truth = LABELS[CLASS_DIRS.index(cdir)]
        direct, cvc = Counter(), Counter()
        for p in sorted((IMAGE_ROOT / cdir).glob("*.jpg")):
            direct[infer(p)[0]] += 1
            c = cv.get(p.name)
            if c:
                cvc[max(c["probs"], key=c["probs"].get)] += 1
        n = sum(direct.values())
        print(f"\n{cdir} {n}장")
        print(f"  원본직접  : {dict(direct.most_common())}")
        print(f"  누수없는CV: {dict(cvc.most_common())}  "
              f"(front 오판 {cvc['front']}장 = {100*cvc['front']/max(1,sum(cvc.values())):.1f}%)")

    print()
    print("=" * 78)
    print("(3) 항목3 — 평면 화살표로 되돌아가는 빈도 (T79 불일치)")
    print("=" * 78)
    fell_back = kept = 0
    for cdir in ("2_front", "3_left", "4_right"):
        for p in sorted((IMAGE_ROOT / cdir).glob("*.jpg")):
            state, _, ang, _ = infer(p)
            if state not in ("front", "left", "right"):
                continue
            if agrees(state, ang):
                kept += 1
            else:
                fell_back += 1
    tot = kept + fell_back
    print(f"  front/left/right로 판정된 {tot}장 중 평면으로 되돌아감: "
          f"{fell_back}장 ({100*fell_back/max(1,tot):.1f}%)")

    print()
    print("=" * 78)
    print("(4) 항목4 — 배포 각도 모델 예측 vs 사람이 매긴 라벨")
    print("=" * 78)
    for cdir in ("2_front", "3_left", "4_right"):
        preds, gs, ws = [], [], []
        for name, (c, gv) in geo.items():
            if c != cdir:
                continue
            p = IMAGE_ROOT / cdir / name
            if not p.exists():
                continue
            preds.append(infer(p)[2])
            gs.append(gv)
            ws.append(wgt.get(name, gv))
        if not preds:
            continue
        preds, gs, ws = np.array(preds), np.array(gs), np.array(ws)
        print(f"\n{cdir} {len(preds)}장 (각도 라벨 있는 것만)")
        print(f"  |예측| 평균 {np.abs(preds).mean():5.1f}도   "
              f"|기하 v3| 평균 {np.abs(gs).mean():5.1f}도   "
              f"|가중| 평균 {np.abs(ws).mean():5.1f}도")
        print(f"  가중 라벨 대비 평균절대오차 {np.abs(preds - ws).mean():.1f}도, "
              f"부호 불일치 {int((np.sign(preds) != np.sign(ws)).sum())}장")


if __name__ == "__main__":
    main()
