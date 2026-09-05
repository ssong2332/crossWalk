"""항목 4 검증 — "노트북 화면으로 봐서 틀린 것인가"를 요인별로 분리한다.

사용자 스크린샷을 보면 카메라 화면에서 **사진은 일부 영역만 차지**하고 주변에
벽·노트북 베젤·키보드가 함께 들어온다. 학습 사진은 화면 전체가 횡단보도다.
즉 노트북 화면 촬영에는 최소 세 가지 요인이 겹친다:
  (F1) 구도 — 사진이 화면의 약 절반만 차지하고 주변에 벽/키보드가 들어옴
  (F2) 화질 — 재촬영에 의한 흐림·모아레
  (F3) 색조 — 화면 발광, 반사, 색온도 차이

이 스크립트는 원본에 (F1),(F1+F2),(F1+F2+F3)을 차례로 입혀 배포 모델에 넣고
정확도가 실기기 수준으로 떨어지는지 본다. 어떤 요인을 넣었을 때 떨어지는지가
곧 원인이다.

한계(정직하게): 구도 비율·배경색은 스크린샷을 눈으로 재어 정한 **근사치**다.
실기기 화면을 픽셀 단위로 복원한 것이 아니므로 결과는 방향을 가리키는 근거이지
정확한 재현이 아니다. 확인 방법: 사용자가 같은 사진을 (a) 화면 가득 차게 띄워
다시 촬영해 판정이 회복되는지 보면 (F1) 단독 효과가 확정된다.

전처리는 앱과 동일(EXIF 회전 미적용, 224 최근접 축소, ImageNet 정규화).
"""
import sys
from collections import Counter
from pathlib import Path

import numpy as np
import onnxruntime as ort
from PIL import Image, ImageFilter

REPO = Path(__file__).resolve().parent.parent
CLS_MODEL = REPO / "crosswalk_app" / "assets" / "model" / "crosswalk_model.onnx"
IMAGE_ROOT = REPO / "image"

CLASS_DIRS = ["0_none", "1_approach", "2_front", "3_left", "4_right"]
LABELS = ["none", "approach", "front", "left", "right"]
THRESHOLDS = {"front": 0.40, "none": 0.40, "approach": 0.40, "left": 0.55, "right": 0.55}
IMG_SIZE = 224
MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)

# 스크린샷에서 눈으로 잰 근사치(핸드폰 화면 963x1919 기준):
#   사진 영역 가로 약 87%, 세로 중심 약 0.50 / 위쪽은 벽, 아래는 노트북 베젤·키보드
PHONE_W, PHONE_H = 963, 1919
PHOTO_W_FRAC = 0.87
PHOTO_CY_FRAC = 0.50
WALL_RGB = (205, 190, 170)      # 벽/책상 (스크린샷의 베이지 톤)
BEZEL_RGB = (35, 35, 38)        # 노트북 베젤
KEYBOARD_RGB = (120, 115, 110)  # 키보드


def tensor(im):
    a = np.asarray(im.convert("RGB"), dtype=np.float32) / 255.0
    a = (a - MEAN) / STD
    return a.transpose(2, 0, 1)[None].astype(np.float32)


def softmax(x):
    e = np.exp(x - x.max())
    return e / e.sum()


def decide(probs):
    i = int(np.argmax(probs))
    lab, conf = LABELS[i], float(probs[i])
    return ("무판정" if conf < THRESHOLDS[lab] else lab), conf


def framed(im_display, blur=False, tint=False):
    """디스플레이 방향 사진을 '노트북 화면을 폰으로 비춘' 구도로 합성한다."""
    canvas = Image.new("RGB", (PHONE_W, PHONE_H), WALL_RGB)

    pw = int(PHONE_W * PHOTO_W_FRAC)
    ph = int(pw * im_display.height / im_display.width)
    px = (PHONE_W - pw) // 2
    py = int(PHONE_H * PHOTO_CY_FRAC) - ph // 2

    # 노트북 베젤(사진 주위 테두리) + 아래쪽 키보드
    canvas.paste(Image.new("RGB", (PHONE_W, ph + 120), BEZEL_RGB), (0, py - 60))
    canvas.paste(Image.new("RGB", (PHONE_W, PHONE_H - (py + ph + 60)), KEYBOARD_RGB),
                 (0, py + ph + 60))

    photo = im_display.resize((pw, ph), Image.BILINEAR)
    if blur:
        # 재촬영 흐림 — 화면 화소를 다시 찍으면 세부가 뭉개진다.
        photo = photo.filter(ImageFilter.GaussianBlur(radius=1.2))
    if tint:
        a = np.asarray(photo, dtype=np.float32)
        # 화면 발광 + 색온도: 대비를 줄이고 자홍 쪽으로 민다(스크린샷의 보라빛).
        a = a * 0.85 + 30
        a[..., 0] *= 1.06
        a[..., 2] *= 1.10
        photo = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))
    canvas.paste(photo, (px, py))
    return canvas


def main():
    per_class_limit = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    sess = ort.InferenceSession(str(CLS_MODEL), providers=["CPUExecutionProvider"])
    inp = sess.get_inputs()[0].name

    variants = ["원본(앱 전처리)", "F1 구도", "F1+F2 흐림", "F1+F2+F3 색조"]
    ok = Counter()
    nocall = Counter()
    per_class = {v: Counter() for v in variants}
    totals = Counter()
    n = 0

    for cdir, truth in zip(CLASS_DIRS, LABELS):
        files = sorted(p for p in (IMAGE_ROOT / cdir).iterdir()
                       if p.suffix.lower() in (".jpg", ".jpeg", ".png"))[:per_class_limit]
        for p in files:
            raw = Image.open(p).convert("RGB")           # 센서 방향 (EXIF 미적용)
            # 합성은 사람이 보는 방향에서 해야 자연스럽다 -> 90도 돌려 세로로 만든 뒤
            # 합성하고, 다시 센서 방향으로 되돌린다.
            disp = raw.transpose(Image.ROTATE_270) if raw.width > raw.height else raw

            imgs = {
                "원본(앱 전처리)": raw,
                "F1 구도": framed(disp).transpose(Image.ROTATE_90),
                "F1+F2 흐림": framed(disp, blur=True).transpose(Image.ROTATE_90),
                "F1+F2+F3 색조": framed(disp, blur=True, tint=True).transpose(Image.ROTATE_90),
            }
            for v, im in imgs.items():
                s, _ = decide(softmax(np.asarray(
                    sess.run(None, {inp: tensor(im.resize((IMG_SIZE, IMG_SIZE), Image.NEAREST))})[0][0])))
                if s == truth:
                    ok[v] += 1
                    per_class[v][truth] += 1
                if s == "무판정":
                    nocall[v] += 1
            totals[truth] += 1
            n += 1

    print(f"평가 {n}장 (클래스당 최대 {per_class_limit}장, 전부 학습 데이터 — "
          f"절대값은 낙관적, 변형 간 상대 차이만 의미 있음)\n")
    print(f"{'변형':16} | {'정확도':>13} | {'무판정':>10} | " +
          " | ".join(f"{l:>8}" for l in LABELS))
    print("-" * 96)
    for v in variants:
        cells = " | ".join(f"{100*per_class[v][l]/max(1,totals[l]):7.1f}%" for l in LABELS)
        print(f"{v:16} | {ok[v]:4d} {100*ok[v]/n:6.1f}% | {nocall[v]:3d} {100*nocall[v]/n:5.1f}% | {cells}")


if __name__ == "__main__":
    main()
