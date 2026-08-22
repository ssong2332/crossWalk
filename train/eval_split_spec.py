"""테스트셋을 '사양 내'(정면에서 살짝 아래 — 배경 보임) / '사양 외'(수직 하방 근접 —
프레임 전체가 노면)로 나눠 현재 모델을 각각 평가한다.

사양 외 인덱스는 train/sheets/test{0,1,2}.jpg 컨택트 시트를 육안 판정한 결과이며
train/testset_index.json 의 순서를 기준으로 한다. 판정 기준(2026-08-21 사용자 확정
사용 각도 "정면에서 살짝 아래"): 지평선/건물/차량/인도 등 배경 맥락이 프레임에
전혀 없고 노면만 100%인 경우 '사양 외'.

전처리·임계값·판정 로직은 train/eval_model.py 와 동일해야 한다(그쪽이 앱과 일치).
"""
import json
from pathlib import Path
import numpy as np
import onnxruntime as ort
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
MODEL = REPO / "model" / "crosswalk_model.onnx"
TEST = REPO / "train" / "data_prepared" / "test"
LABELS = ["front", "left", "none", "right"]
MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)
IMG_SIZE = 224
FRONT_T, DEV_T, NONE_T = 0.5, 0.55, 0.50

OFF_SPEC_IDX = {1, 2, 10, 11, 23, 35, 37, 45, 46, 47, 55, 72, 86, 87}


def preprocess(p):
    img = Image.open(p).convert("RGB").resize((IMG_SIZE, IMG_SIZE), Image.NEAREST)
    a = np.asarray(img, dtype=np.float32) / 255.0
    a = (a - MEAN) / STD
    return np.expand_dims(a.transpose(2, 0, 1), 0).astype(np.float32)


def softmax(x):
    e = np.exp(x - np.max(x))
    return e / e.sum()


def decide(probs):
    i = int(np.argmax(probs))
    lab = LABELS[i]
    t = FRONT_T if lab == "front" else (NONE_T if lab == "none" else DEV_T)
    return lab if probs[i] >= t else None


def report(name, recs):
    print(f"\n{'='*66}\n{name}  (n={len(recs)})\n{'='*66}")
    if not recs:
        print("  표본 없음")
        return
    for lab in LABELS:
        sub = [r for r in recs if r[0] == lab]
        if not sub:
            print(f"  {lab:6s}: 표본 없음")
            continue
        hit = sum(1 for r in sub if r[1] == lab)
        # precision: 이 라벨로 예측한 것 중 맞은 비율
        pred_as = [r for r in recs if r[1] == lab]
        prec = (sum(1 for r in pred_as if r[0] == lab) / len(pred_as)) if pred_as else float("nan")
        none_cnt = sum(1 for r in sub if r[1] is None)
        wrong = [r[1] for r in sub if r[1] is not None and r[1] != lab]
        print(f"  {lab:6s}: recall={hit/len(sub):.3f} ({hit}/{len(sub)})  "
              f"precision={prec:.3f}  무판정={none_cnt}  오판={wrong}")
    fr = [r for r in recs if r[0] == "front"]
    if fr:
        fa = sum(1 for r in fr if r[1] in ("left", "right"))
        print(f"  >> front 오경보(직진->편향): {fa}/{len(fr)} = {fa/len(fr)*100:.1f}%")


def main():
    sess = ort.InferenceSession(str(MODEL))
    inp = sess.get_inputs()[0].name
    items = json.load(open(REPO / "train" / "testset_index.json", encoding="utf-8"))
    on, off = [], []
    for idx, (cls, fn) in enumerate(items):
        probs = softmax(np.array(sess.run(None, {inp: preprocess(TEST / cls / fn)})[0][0]))
        rec = (cls, decide(probs), fn)
        (off if idx in OFF_SPEC_IDX else on).append(rec)
    report("전체 (기존 측정과 동일)", on + off)
    report("사양 내 — 정면에서 살짝 아래 (실사용 조건)", on)
    report("사양 외 — 수직 하방 근접 (실사용에서 발생 안 함)", off)


if __name__ == "__main__":
    main()
