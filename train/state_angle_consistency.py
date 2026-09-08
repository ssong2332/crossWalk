"""T79 진단 — (1) 상태 판정과 각도가 서로 모순되는 빈도, (2) 횡단보도 위/앞 구분.

배경 (2026-09-07, 사용자 실기기 스크린샷 11장):
  "방향 판단은 맞는데 화살표와 각도 판정이 미흡하다. 횡단보도 위와 앞 판단도
   안 되어 있다."
  스크린샷 중 1장이 **왼쪽으로 틀어짐(오른쪽으로 가라)인데 보정 -2**로 거의
  직진을 가리켰다. 라벨 규약상 3_left는 전부 양수, 4_right는 전부 음수이므로
  (T71 검증) 이것은 두 모델이 서로 반대를 말한 경우다.

이 스크립트는 두 가지를 실측한다:
  (A) 배포 모델 그대로(실기기와 동일 경로): 분류기 상태와 각도 부호가
      얼마나 자주 어긋나는가. 화살표가 "직진처럼 보이는"(|각도|<5도) 채로
      이탈 경고가 나가는 빈도도 함께 센다.
  (B) 누수 없는 5-fold CV로 approach(횡단보도 앞) vs front/left/right
      (횡단보도 위)의 혼동을 본다.

전처리는 앱과 동일하게 맞춘다:
  - 분류기: EXIF 회전 **미적용**(학습 build_cache.py:53과 앱 센서버퍼 둘 다 미적용),
            224 축소는 **BOX(=Interpolation.average)** — T77로 앱이 이걸 쓴다.
  - 각도  : EXIF 회전 **적용**(train_angle.py:216), 중앙 224/288 크롭 + 3x3 평균
            (angle_estimator.dart와 동일).

주의(중요): (A)의 두 모델은 이 사진들로 학습됐으므로 절대 정확도는 낙관적이다.
  의미가 있는 것은 **두 출력이 서로 모순되는 비율**이며, 그것은 학습 데이터에서도
  0이어야 정상이다(같은 사진을 보고 한쪽은 왼쪽, 한쪽은 오른쪽이라 말하면 안 된다).
  (B)는 누수 없는 CV라 일반화 성능의 정직한 값이다.
"""
import csv
import json
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
import onnxruntime as ort
from PIL import Image, ImageOps

REPO = Path(__file__).resolve().parent.parent
ASSETS = REPO / "crosswalk_app" / "assets" / "model"
IMAGE_ROOT = REPO / "image"

CLASS_DIRS = ["0_none", "1_approach", "2_front", "3_left", "4_right"]
LABELS = ["none", "approach", "front", "left", "right"]
THRESHOLDS = {"front": 0.40, "none": 0.40, "approach": 0.40,
              "left": 0.55, "right": 0.55}

IMG = 224
CROP_RATIO = 224.0 / 288.0
GRID = 3
ANGLE_SCALE = 90.0
MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)

# 화살표가 사람 눈에 "직진"으로 보이는 폭. T74에서 확인한 v2 라벨의 front 범위
# (±2.6도)와 이탈 시작(±5.0도)을 근거로 5도를 쓴다.
STRAIGHT_LOOKING_DEG = 5.0


def cls_tensor(path):
    im = Image.open(path).convert("RGB")            # EXIF 회전 미적용
    im = im.resize((IMG, IMG), Image.BOX)           # T77: average와 동일 연산
    a = np.asarray(im, dtype=np.float32) / 255.0
    return ((a - MEAN) / STD).transpose(2, 0, 1)[None].astype(np.float32)


def angle_tensor(path):
    im = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    arr = np.asarray(im, dtype=np.float32)
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


def expected_sign(state):
    """라벨 규약: 왼쪽 이탈은 양수, 오른쪽 이탈은 음수 (T71 검증)."""
    return {"left": +1, "right": -1}.get(state)


def main():
    cls_sess = ort.InferenceSession(
        str(ASSETS / "crosswalk_model.onnx"), providers=["CPUExecutionProvider"])
    ang_sess = ort.InferenceSession(
        str(ASSETS / "crosswalk_angle.onnx"), providers=["CPUExecutionProvider"])
    cin = cls_sess.get_inputs()[0].name
    ain = ang_sess.get_inputs()[0].name

    # 각도 라벨이 있는 사진만 (0_none은 각도라는 개념이 없다)
    labels = {}
    with open(REPO / "train/angle_labels.csv", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            if r["status"] == "ok":
                labels[r["filename"]] = (r["class"], float(r["angle_deg"]))

    rows = []
    for name, (cdir, gt_angle) in labels.items():
        p = IMAGE_ROOT / cdir / name
        if not p.exists():
            continue
        state, conf = decide(softmax(
            np.asarray(cls_sess.run(None, {cin: cls_tensor(p)})[0][0])))
        ang = float(np.asarray(
            ang_sess.run(None, {ain: angle_tensor(p)})[0]).ravel()[0]) * ANGLE_SCALE
        truth = LABELS[CLASS_DIRS.index(cdir)]
        rows.append((name, truth, state, conf, ang, gt_angle))

    print("=" * 78)
    print(f"(A) 배포 모델 그대로 — 상태 vs 각도 모순  (평가 {len(rows)}장)")
    print("    주의: 학습 데이터라 절대 정확도는 낙관적. 모순 비율만 의미 있음.")
    print("=" * 78)

    dev = [r for r in rows if r[2] in ("left", "right")]
    sign_bad = [r for r in dev if np.sign(r[4]) != expected_sign(r[2]) and r[4] != 0]
    straightish = [r for r in dev if abs(r[4]) < STRAIGHT_LOOKING_DEG]
    print(f"\n분류기가 이탈(left/right)이라 말한 사진: {len(dev)}장")
    print(f"  - 각도 부호가 **반대**: {len(sign_bad)}장 "
          f"({100*len(sign_bad)/max(1,len(dev)):.1f}%) "
          f"— 문구는 '오른쪽으로'인데 화살표는 왼쪽을 가리키는 경우")
    print(f"  - 각도가 |{STRAIGHT_LOOKING_DEG:.0f}도| 미만이라 화살표가 사실상 직진: "
          f"{len(straightish)}장 ({100*len(straightish)/max(1,len(dev)):.1f}%) "
          f"— 사용자 스크린샷 5번(왼쪽 틀어짐, 보정 -2)이 이 경우")
    bad_union = {r[0] for r in sign_bad} | {r[0] for r in straightish}
    print(f"  - 둘 중 하나라도 해당(화살표가 경고와 어긋남): {len(bad_union)}장 "
          f"({100*len(bad_union)/max(1,len(dev)):.1f}%)")

    print(f"\n  [예시 10장]")
    for r in sorted(dev, key=lambda r: abs(r[4]))[:10]:
        flag = "부호반대" if np.sign(r[4]) != expected_sign(r[2]) and r[4] != 0 else "거의직진"
        print(f"    {r[0]:32} 정답={r[1]:6} 상태={r[2]:6} "
              f"각도={r[4]:+7.1f} (라벨 {r[5]:+6.1f})  <- {flag}")

    print(f"\n정답 클래스 기준 각도 부호 정확도 (분류기와 무관하게 각도 모델만):")
    for cls in ("left", "right"):
        sub = [r for r in rows if r[1] == cls]
        ok = [r for r in sub if np.sign(r[4]) == expected_sign(cls)]
        near0 = [r for r in sub if abs(r[4]) < STRAIGHT_LOOKING_DEG]
        print(f"    {cls:6}: {len(ok)}/{len(sub)} = "
              f"{100*len(ok)/max(1,len(sub)):.1f}% 부호 일치, "
              f"|각도|<{STRAIGHT_LOOKING_DEG:.0f}도 {len(near0)}장")

    print()
    print("=" * 78)
    print("(B) 누수 없는 5-fold CV — 횡단보도 '앞'(approach) vs '위'(front/left/right)")
    print("=" * 78)
    cv = json.load(open(REPO / "train/groupkfold_5class_out/all_probs.json",
                        encoding="utf-8"))
    conf_mat = defaultdict(Counter)
    for r in cv:
        st, _ = decide(np.array([r["probs"][l] for l in LABELS], dtype=np.float32))
        conf_mat[r["true"]][st] += 1

    cols = LABELS + ["무판정"]
    print(f"\n{'정답\\판정':10} | " + " | ".join(f"{c:>7}" for c in cols) + " |   합계")
    print("-" * 78)
    for t in LABELS:
        row = conf_mat[t]
        n = sum(row.values())
        print(f"{t:10} | " + " | ".join(f"{row[c]:7d}" for c in cols) + f" | {n:7d}")

    on = ("front", "left", "right")
    ap_n = sum(conf_mat["approach"].values())
    ap_to_on = sum(conf_mat["approach"][c] for c in on)
    on_n = sum(sum(conf_mat[t].values()) for t in on)
    on_to_ap = sum(conf_mat[t]["approach"] for t in on)
    print(f"\n  앞(approach) -> 위로 오판: {ap_to_on}/{ap_n} = "
          f"{100*ap_to_on/max(1,ap_n):.1f}%")
    print(f"  위(front/left/right) -> 앞으로 오판: {on_to_ap}/{on_n} = "
          f"{100*on_to_ap/max(1,on_n):.1f}%")
    print(f"  approach recall: {conf_mat['approach']['approach']}/{ap_n} = "
          f"{100*conf_mat['approach']['approach']/max(1,ap_n):.1f}%")
    pred_ap = sum(conf_mat[t]["approach"] for t in LABELS)
    print(f"  approach precision: {conf_mat['approach']['approach']}/{pred_ap} = "
          f"{100*conf_mat['approach']['approach']/max(1,pred_ap):.1f}%")


if __name__ == "__main__":
    main()
