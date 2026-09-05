"""항목 2 검증 — "화살표가 횡단보도와 일치하지 않는다"를 정량화하고
기하 각도를 라벨 없이 자동으로 뽑을 수 있는지(Hough) 타당성을 실측한다.

두 가지를 잰다:
  (1) 사람이 그은 화살표 각도(angle_labels.csv의 x1,y1,x2,y2로 계산)와
      **횡단보도 줄무늬에서 자동으로 뽑은 기하 각도**가 얼마나 어긋나는가.
  (2) 그 어긋남이 위치 라벨(position_labels.csv)과 함께 커지는가 —
      T74에서 확인된 위험 가중(+7.3도/위치 등급)이 원인이라면 그래야 한다.

각도 규약(라벨과 동일): 화면 위쪽 = 0도, 시계방향 +.
  label_angle = atan2(dx, -dy),  dx = x2-x1, dy = y2-y1
  (실측 확인: 수직선 (292,334)->(292,187)이 angle_deg 0.00)

기하 각도 추정 방법:
  횡단보도 흰 띠의 **긴 모서리**는 보행 방향과 나란하지 않고, 띠 자체는 보행
  방향에 수직이다. 그래서 Hough로 우세 직선 방향 theta를 구한 뒤 90도를 돌려
  보행 방향으로 삼는다. 원근 때문에 완벽하지 않으므로 이 스크립트의 목적은
  "정밀한 값"이 아니라 **자동 추출이 쓸 만한 신호를 주는지** 판정하는 것이다.

판정 기준(미리 고정):
  - 검출 실패율이 30%를 넘으면 자동 추출 단독으로는 불가.
  - 사람 라벨과의 상관계수가 0.5 미만이면 신호가 약한 것으로 본다.
"""
import csv
import math
from collections import defaultdict
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageOps

REPO = Path(__file__).resolve().parent.parent
IMAGE_ROOT = REPO / "image"
WORK_W = 640          # 처리용 축소 폭
MIN_LINES = 6         # 이보다 적게 잡히면 검출 실패로 본다


def label_angle(r):
    dx = float(r["x2"]) - float(r["x1"])
    dy = float(r["y2"]) - float(r["y1"])
    return math.degrees(math.atan2(dx, -dy))


def wrap90(a):
    """-90 < a <= 90 으로 접는다(직선은 180도 주기라서)."""
    while a <= -90:
        a += 180
    while a > 90:
        a -= 180
    return a


def stripe_angle(path):
    """횡단보도 줄무늬에서 보행 방향 각도(도)를 추정한다. 실패하면 None."""
    im = ImageOps.exif_transpose(Image.open(path)).convert("L")
    w, h = im.size
    scale = WORK_W / w
    im = im.resize((WORK_W, int(h * scale)), Image.BILINEAR)
    g = np.asarray(im)

    # 아래쪽 60%만 본다 — 발밑 횡단보도가 여기 있고, 위쪽은 건물/하늘/차량이다.
    g = g[int(g.shape[0] * 0.40):, :]
    g = cv2.GaussianBlur(g, (5, 5), 0)
    edges = cv2.Canny(g, 50, 150)

    lines = cv2.HoughLinesP(edges, 1, np.pi / 180, threshold=60,
                            minLineLength=int(WORK_W * 0.15), maxLineGap=20)
    if lines is None or len(lines) < MIN_LINES:
        return None

    # 길이 가중 방향 히스토그램 (1도 단위, 180도 주기)
    hist = np.zeros(180, dtype=np.float64)
    for x1, y1, x2, y2 in lines[:, 0]:
        dx, dy = float(x2 - x1), float(y2 - y1)
        ln = math.hypot(dx, dy)
        a = int(round(math.degrees(math.atan2(dy, dx)))) % 180
        hist[a] += ln
    # 주기성을 고려해 원형 평활화
    k = np.array([1, 2, 3, 4, 5, 4, 3, 2, 1], dtype=np.float64)
    sm = np.convolve(np.r_[hist, hist, hist], k, mode="same")[180:360]
    dom = int(np.argmax(sm))                      # 우세 직선 방향(이미지 좌표계)

    if sm[dom] <= 0:
        return None

    # 띠 방향 -> 보행 방향은 수직. 화면 위=0, 시계+ 규약으로 변환.
    # 이미지 좌표 방향 dom(도, x축 기준, y 아래) 벡터 = (cos dom, sin dom)
    # 수직 벡터 = (-sin dom, cos dom) -> 화면 규약 atan2(dx, -dy)
    rad = math.radians(dom)
    vx, vy = -math.sin(rad), math.cos(rad)
    return wrap90(math.degrees(math.atan2(vx, -vy)))


def main():
    labels, positions = {}, {}
    with open(REPO / "train/angle_labels.csv", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            if r["status"] == "ok":
                labels[r["filename"]] = (r["class"], float(r["angle_deg"]), label_angle(r))
    with open(REPO / "train/position_labels.csv", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            if r["status"] == "ok":
                positions[r["filename"]] = int(r["position"])

    rows = []
    fails = 0
    for name, (cls, ang_csv, ang_calc) in labels.items():
        p = IMAGE_ROOT / cls / name
        if not p.exists():
            continue
        est = stripe_angle(p)
        if est is None:
            fails += 1
            continue
        rows.append((name, cls, ang_csv, est, positions.get(name)))

    n = len(rows)
    print(f"라벨 {len(labels)}장 중 기하 추정 성공 {n}장, 실패 {fails}장 "
          f"(실패율 {100*fails/max(1,len(labels)):.1f}%)")
    if n == 0:
        return

    lab = np.array([r[2] for r in rows])
    est = np.array([r[3] for r in rows])
    diff = lab - est
    corr = float(np.corrcoef(lab, est)[0, 1])
    print(f"\n사람 라벨 vs 기하 추정: 상관 {corr:.3f}, "
          f"평균차 {diff.mean():+.1f}도, 절대차 평균 {np.abs(diff).mean():.1f}도, "
          f"중앙 {np.median(np.abs(diff)):.1f}도")

    print(f"\n{'클래스':10} | {'n':>4} | {'라벨평균':>8} | {'기하평균':>8} | {'차이평균':>8} | 상관")
    print("-" * 62)
    by = defaultdict(list)
    for name, cls, a, e, pos in rows:
        by[cls].append((a, e))
    for cls in sorted(by):
        arr = np.array(by[cls])
        c = float(np.corrcoef(arr[:, 0], arr[:, 1])[0, 1]) if len(arr) > 2 else float("nan")
        print(f"{cls:10} | {len(arr):4d} | {arr[:,0].mean():+8.1f} | {arr[:,1].mean():+8.1f} | "
              f"{(arr[:,0]-arr[:,1]).mean():+8.1f} | {c:.3f}")

    # 위치 등급별 — 위험 가중이 원인이면 위험쪽으로 갈수록 차이가 커져야 한다.
    print(f"\n{'위치등급':10} | {'n':>4} | {'라벨-기하 평균차':>14}")
    print("-" * 40)
    bypos = defaultdict(list)
    for name, cls, a, e, pos in rows:
        if pos is None:
            continue
        bypos[pos].append(a - e)
    for pos in sorted(bypos):
        v = np.array(bypos[pos])
        print(f"{pos:+10d} | {len(v):4d} | {v.mean():+14.1f}")


if __name__ == "__main__":
    main()
