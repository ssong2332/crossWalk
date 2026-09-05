"""실기기(노트북 화면 촬영) 결과 vs 원본 직접 추론 — 오분류 원인 분리.

사용자가 2026-09-05에 보낸 실기기 스크린샷 12장은 **노트북 화면에 띄운 학습 사진**을
휴대폰으로 비춘 것이고, 화면 상단에 원본 파일명이 그대로 찍혀 있다.
그래서 같은 파일을 원본 그대로 배포 모델에 넣어 비교하면
"화면 촬영 때문인가 / 모델 자체가 못 맞히는가"를 가를 수 있다.

비교 3종:
  (A) 화면표시   = 실기기가 노트북 화면을 보고 낸 판정 (스크린샷에서 전사)
  (B) 원본직접   = 같은 배포 ONNX + 앱과 동일한 전처리로 원본 파일을 직접 추론
  (C) 누수없는CV = 그 파일을 학습에서 제외한 fold의 예측 (일반화 성능의 정직한 값)

읽는 법:
  정답==B != A            -> 노트북 화면(촬영 매체)이 원인
  정답!=B, 정답!=C        -> 모델 자체의 오류 (화면과 무관)
  정답==B, 정답!=C        -> 모델이 이 사진을 외운 것 (B는 낙관적, C가 진짜 실력)

주의: (A)는 5프레임 평균 스무딩이 걸린 값이고 (B)는 단발 추론이다.
      각도의 '원시'는 스무딩 전 값이라 (B)와 직접 비교 가능하다.
"""
import csv
import json
from pathlib import Path

import numpy as np
import onnxruntime as ort
from PIL import Image, ImageOps

REPO = Path(__file__).resolve().parent.parent
ASSETS = REPO / "crosswalk_app" / "assets" / "model"
CLS_MODEL = ASSETS / "crosswalk_model.onnx"
ANG_MODEL = ASSETS / "crosswalk_angle.onnx"
IMAGE_ROOT = REPO / "image"

CLASS_DIRS = ["0_none", "1_approach", "2_front", "3_left", "4_right"]
LABELS = ["none", "approach", "front", "left", "right"]
THRESHOLDS = {"front": 0.40, "none": 0.40, "approach": 0.40, "left": 0.55, "right": 0.55}

IMG_SIZE = 224
CROP_RATIO = 224.0 / 288.0
SAMPLE_GRID = 3
ANGLE_SCALE = 90.0
MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)

# 스크린샷 12장에서 전사한 값: (파일명, 화면판정, 신뢰도%, 보정, 원시)
SCREEN = [
    ("20260708_201944.jpg", "right", 56, 7, 4),
    ("20260708_202951.jpg", "front", 48, 12, 15),
    ("20260708_201641.jpg", "left", 57, 4, 5),
    ("20260722_133716.jpg", "front", 50, -1, -1),
    ("20251118_132013_049_saved.jpg", "right", 56, -9, -13),
    ("20251119_154949.jpg", "front", 62, -1, -2),
    ("20260719_141247.jpg", "front", 61, 9, 10),
    ("20260828_104040.jpg", "front", 58, -13, -13),
    ("20260828_104042.jpg", "right", 97, -15, -17),
    ("20260828_104621.jpg", "right", 93, -17, -17),
    ("20260828_104642.jpg", "front", 46, -1, 0),
    ("20260708_203305.jpg", "front", 40, 7, 9),
]


def find_image(name):
    for d, lab in zip(CLASS_DIRS, LABELS):
        p = IMAGE_ROOT / d / name
        if p.exists():
            return p, lab
    return None, None


def preprocess_classifier(path, filt=Image.NEAREST):
    """classifier.dart와 동일: 화면 이미지를 224 리사이즈 + ImageNet 정규화.

    filt=NEAREST가 앱의 실제 경로(`img.copyResize` 기본값), BILINEAR는 학습 전처리.

    **EXIF 회전을 적용하지 않는다** — 학습(`build_cache.py:53`)이 일부러 적용하지
    않으며, 앱도 센서 버퍼(가로)를 회전 없이 그대로 넣기 때문이다. 여기서 보정하면
    학습/앱 어느 쪽과도 다른 입력이 되어 모델이 전부 none을 낸다(실측 확인).
    """
    im = Image.open(path).convert("RGB")
    im = im.resize((IMG_SIZE, IMG_SIZE), filt)
    a = np.asarray(im, dtype=np.float32) / 255.0
    a = (a - MEAN) / STD
    return a.transpose(2, 0, 1)[None].astype(np.float32)


def preprocess_angle(path):
    """angle_estimator.dart와 동일: 중앙 224/288 크롭 + 3x3 격자 평균 + 정규화."""
    im = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    arr = np.asarray(im, dtype=np.float32)
    dH, dW = arr.shape[0], arr.shape[1]
    cw, ch = int(dW * CROP_RATIO), int(dH * CROP_RATIO)
    ox, oy = (dW - cw) // 2, (dH - ch) // 2

    g = SAMPLE_GRID
    # Dart의 정수 나눗셈 인덱싱을 그대로 재현한다.
    ys = oy + (np.arange(IMG_SIZE * g) * ch) // (IMG_SIZE * g)
    xs = ox + (np.arange(IMG_SIZE * g) * cw) // (IMG_SIZE * g)
    sub = arr[np.ix_(ys, xs)]                                   # (224g, 224g, 3)
    sub = sub.reshape(IMG_SIZE, g, IMG_SIZE, g, 3).mean(axis=(1, 3))
    a = sub / 255.0
    a = (a - MEAN) / STD
    return a.transpose(2, 0, 1)[None].astype(np.float32)


def softmax(x):
    e = np.exp(x - x.max())
    return e / e.sum()


def decide(probs):
    i = int(np.argmax(probs))
    lab, conf = LABELS[i], float(probs[i])
    return ("무판정" if conf < THRESHOLDS[lab] else lab), conf


def main():
    cls_sess = ort.InferenceSession(str(CLS_MODEL), providers=["CPUExecutionProvider"])
    ang_sess = ort.InferenceSession(str(ANG_MODEL), providers=["CPUExecutionProvider"])
    cls_in = cls_sess.get_inputs()[0].name
    ang_in = ang_sess.get_inputs()[0].name

    cv = {r["file"]: r for r in json.load(
        open(REPO / "train/groupkfold_5class_out/all_probs.json", encoding="utf-8"))}

    ang_label, pos_label = {}, {}
    with open(REPO / "train/angle_labels.csv", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            if r["status"] == "ok":
                ang_label[r["filename"]] = float(r["angle_deg"])
    with open(REPO / "train/position_labels.csv", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            if r["status"] == "ok":
                pos_label[r["filename"]] = int(r["position"])

    rows = []
    for name, scr_state, scr_conf, scr_corr, scr_raw in SCREEN:
        path, truth = find_image(name)
        if path is None:
            print(f"[건너뜀] 저장소에 없는 파일: {name}")
            continue

        probs = softmax(np.asarray(cls_sess.run(None, {cls_in: preprocess_classifier(path)})[0][0]))
        orig_state, orig_conf = decide(probs)
        probs_b = softmax(np.asarray(cls_sess.run(
            None, {cls_in: preprocess_classifier(path, Image.BILINEAR)})[0][0]))
        bil_state, bil_conf = decide(probs_b)

        ang = float(np.asarray(ang_sess.run(None, {ang_in: preprocess_angle(path)})[0]).ravel()[0]) * ANGLE_SCALE

        c = cv.get(name)
        if c:
            cvp = np.array([c["probs"][l] for l in LABELS], dtype=np.float32)
            cv_state, cv_conf = decide(cvp)
        else:
            cv_state, cv_conf = "?", float("nan")

        rows.append((
            name, truth,
            f"{scr_state} {scr_conf}%",
            f"{orig_state} {orig_conf*100:.0f}%",
            f"{bil_state} {bil_conf*100:.0f}%",
            f"{cv_state} {cv_conf*100:.0f}%",
            scr_raw, f"{ang:.0f}",
            ang_label.get(name, "-"), pos_label.get(name, "-"),
        ))

    hdr = ("파일", "정답", "(A)화면", "(B)원본-nearest(앱)", "(B2)원본-bilinear(학습)",
           "(C)누수없는CV", "화면각도(원시)", "원본각도", "각도라벨", "위치라벨")
    w = [max(len(str(r[i])) for r in rows + [hdr]) for i in range(len(hdr))]
    print(" | ".join(str(h).ljust(w[i]) for i, h in enumerate(hdr)))
    print("-+-".join("-" * x for x in w))
    for r in rows:
        print(" | ".join(str(v).ljust(w[i]) for i, v in enumerate(r)))

    n = len(rows)
    ok_screen = sum(1 for r in rows if r[2].split()[0] == r[1])
    ok_near = sum(1 for r in rows if r[3].split()[0] == r[1])
    ok_bil = sum(1 for r in rows if r[4].split()[0] == r[1])
    ok_cv = sum(1 for r in rows if r[5].split()[0] == r[1])
    print(f"\n정답 일치: (A)화면 {ok_screen}/{n}  (B)nearest(앱) {ok_near}/{n}  "
          f"(B2)bilinear(학습) {ok_bil}/{n}  (C)누수없는CV {ok_cv}/{n}")

    # 화면-원본이 갈린 건수 = 촬영 매체가 바꾼 판정
    diff = [r for r in rows if r[2].split()[0] != r[3].split()[0]]
    print(f"화면과 원본(앱 전처리)의 판정이 다른 사진: {len(diff)}/{n}")
    for r in diff:
        print(f"  - {r[0]}: 정답 {r[1]} / 화면 {r[2]} / nearest {r[3]} / bilinear {r[4]} / CV {r[5]}")

    # 각도 차이
    print("\n각도(원시) 화면 vs 원본:")
    for r in rows:
        print(f"  - {r[0]}: 화면 {r[6]}도 / 원본 {r[7]}도 / 라벨 {r[8]}도 "
              f"(차이 {abs(float(r[7])-float(r[6])):.0f}도)")


if __name__ == "__main__":
    main()
