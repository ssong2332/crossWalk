"""분류기 전처리 불일치 검증 — 앱은 최근접(nearest) 축소, 학습은 BILINEAR.

배경: T70-2에서 **각도 모델**에 대해 같은 문제를 찾아 고쳤다
  (앱이 1280폭을 224로 줄이며 점 하나씩만 찍어 읽어 줄무늬가 앨리어싱으로 뭉개짐,
   16.0도 -> 13.3도로 개선). 그때 고친 것은 `angle_estimator.dart`뿐이고
  `classifier.dart._preprocessCamera`의 `img.copyResize(...)`는 그대로 남아 있다
  (image 패키지 기본값 = Interpolation.nearest).
  학습 입력은 `build_cache.py`의 `transforms.Resize((224,224))` = **BILINEAR(안티에일리어싱)**.

이 스크립트는 배포 중인 ONNX 하나로 같은 사진을 두 전처리로 각각 추론해
그 차이가 실제 판정에 영향을 주는지 **실측**한다.

주의(중요): 여기 쓰는 사진은 전부 배포 모델의 학습 데이터라 절대 정확도는
낙관적이다. 의미가 있는 것은 **두 전처리 사이의 상대 차이**뿐이다.
"""
import json
import sys
from collections import Counter
from pathlib import Path

import numpy as np
import onnxruntime as ort
from PIL import Image, ImageOps

REPO = Path(__file__).resolve().parent.parent
CLS_MODEL = REPO / "crosswalk_app" / "assets" / "model" / "crosswalk_model.onnx"
IMAGE_ROOT = REPO / "image"

CLASS_DIRS = ["0_none", "1_approach", "2_front", "3_left", "4_right"]
LABELS = ["none", "approach", "front", "left", "right"]
THRESHOLDS = {"front": 0.40, "none": 0.40, "approach": 0.40, "left": 0.55, "right": 0.55}
IMG_SIZE = 224
MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)


def tensor(im):
    a = np.asarray(im, dtype=np.float32) / 255.0
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
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    sess = ort.InferenceSession(str(CLS_MODEL), providers=["CPUExecutionProvider"])
    inp = sess.get_inputs()[0].name

    stats = {"nearest": Counter(), "bilinear": Counter()}
    per_class = {"nearest": Counter(), "bilinear": Counter()}
    totals = Counter()
    changed = []
    n = 0

    for cdir, truth in zip(CLASS_DIRS, LABELS):
        files = sorted(p for p in (IMAGE_ROOT / cdir).iterdir()
                       if p.suffix.lower() in (".jpg", ".jpeg", ".png"))
        if limit:
            files = files[:limit]
        for p in files:
            # EXIF 회전 미적용 — 학습(build_cache.py:53)과 앱(센서 버퍼 그대로) 둘 다 미적용.
            im = Image.open(p).convert("RGB")
            near = im.resize((IMG_SIZE, IMG_SIZE), Image.NEAREST)
            bil = im.resize((IMG_SIZE, IMG_SIZE), Image.BILINEAR)

            sn, cn = decide(softmax(np.asarray(sess.run(None, {inp: tensor(near)})[0][0])))
            sb, cb = decide(softmax(np.asarray(sess.run(None, {inp: tensor(bil)})[0][0])))

            totals[truth] += 1
            n += 1
            if sn == truth:
                stats["nearest"]["ok"] += 1
                per_class["nearest"][truth] += 1
            if sb == truth:
                stats["bilinear"]["ok"] += 1
                per_class["bilinear"][truth] += 1
            if sn == "무판정":
                stats["nearest"]["무판정"] += 1
            if sb == "무판정":
                stats["bilinear"]["무판정"] += 1
            if sn != sb:
                changed.append((p.name, truth, sn, round(cn, 3), sb, round(cb, 3)))

    print(f"평가 장수: {n}  (전부 학습 데이터 — 절대값은 낙관적, 상대 차이만 의미 있음)\n")
    print(f"{'클래스':10} | {'n':>4} | {'앱(nearest)':>12} | {'학습(bilinear)':>14} | 차이")
    print("-" * 62)
    for lab in LABELS:
        t = totals[lab]
        if not t:
            continue
        a, b = per_class["nearest"][lab], per_class["bilinear"][lab]
        print(f"{lab:10} | {t:4d} | {a:5d} {100*a/t:5.1f}% | {b:5d} {100*b/t:6.1f}% | {100*(b-a)/t:+5.1f}%p")
    a, b = stats["nearest"]["ok"], stats["bilinear"]["ok"]
    print("-" * 62)
    print(f"{'전체':10} | {n:4d} | {a:5d} {100*a/n:5.1f}% | {b:5d} {100*b/n:6.1f}% | {100*(b-a)/n:+5.1f}%p")
    print(f"{'무판정':10} | {n:4d} | {stats['nearest']['무판정']:5d} "
          f"{100*stats['nearest']['무판정']/n:5.1f}% | {stats['bilinear']['무판정']:5d} "
          f"{100*stats['bilinear']['무판정']/n:6.1f}% |")

    print(f"\n두 전처리가 서로 다른 판정을 낸 사진: {len(changed)}/{n} = {100*len(changed)/n:.1f}%")
    fixed = [c for c in changed if c[4] == c[1] and c[2] != c[1]]
    broke = [c for c in changed if c[2] == c[1] and c[4] != c[1]]
    print(f"  bilinear가 맞히고 nearest가 틀린 경우: {len(fixed)}")
    print(f"  nearest가 맞히고 bilinear가 틀린 경우: {len(broke)}")
    print("\n예시 (앞 15건):")
    for c in changed[:15]:
        print(f"  {c[0]:32} 정답={c[1]:8} nearest={c[2]:8}({c[3]:.2f})  bilinear={c[4]:8}({c[5]:.2f})")

    json.dump(changed, open(REPO / "train" / "resize_mismatch_changed.json", "w",
                            encoding="utf-8"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
