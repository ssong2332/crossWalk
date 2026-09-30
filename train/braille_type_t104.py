"""T104: 점자블록 영역을 선형(유도)/점형(정지·경고)으로 **모양으로 자동 분류**한다.

AI Hub 라벨은 braille_guide_blocks 하나뿐(속성 normal/damaged)이라 두 종류를
구분하지 않는다. 사용자 결정(2026-09-28, 3안): 모양으로 먼저 나누고 사람이
표본을 검수한다(`review_braille_t104.py`).

대상: `braille_count_t104.csv`에서 발 앞(front_pct >= 5)인 사진.

영역별 특징(폴리곤을 1/4 크기 마스크로 그려 픽셀 좌표의 주축을 구한다):
  elong   = 주축 길이 / 부축 길이 (sqrt(고유값 비))
  tilt    = 주축이 화면 세로축과 이루는 각(0 = 세로, 90 = 가로)
  front   = 발 앞 영역(가로 가운데 1/3 × 아래 1/2)과 겹치는 픽셀 비율

판정표 (영역 단위):
  | 조건                                   | 자동 판정 |
  | elong >= ELONG_T 그리고 tilt <= TILT_T | 선형      |  (앞으로 뻗은 가는 띠)
  | 그 외                                  | 점형      |  (넓은 면, 또는 가로로 놓인 띠 = 연석 앞 경고선)
사진 단위: 발 앞 영역과 겹치는(front >= 0.05) 영역들의 판정을 모은다
  | 선형만 -> linear | 점형만 -> dot | 둘 다 -> both |
  | 발 앞 영역이 하나도 없음(각 영역의 발 앞 비중 < 5%) -> dot |
    (사용자 결정 A안, 2026-09-28: 검수에서 자동 '없음' 8장 중 7장이 점형이었다 —
     `review_t104_braille/type_review_log.csv`)
기준값은 추정이다 — 검수 결과로 정확도를 재고 필요하면 바꾼다.

출력: train/braille_type_auto_t104.csv (사진별), 표준출력 분포 요약.
실행: python train/braille_type_t104.py
"""
import csv
import glob
import os
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict

import numpy as np
from PIL import Image, ImageDraw

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(REPO, "aihub_raw", "surface")
COUNT_CSV = os.path.join(REPO, "train", "braille_count_t104.csv")
OUT = os.path.join(REPO, "train", "braille_type_auto_t104.csv")
SCALE = 4
ELONG_T = float(os.environ.get("BRAILLE_ELONG_T", "3.0"))
TILT_T = float(os.environ.get("BRAILLE_TILT_T", "45"))
FRONT_T = 0.05


def poly_features(pts, w, h):
    mw, mh = w // SCALE, h // SCALE
    m = Image.new("L", (mw, mh), 0)
    ImageDraw.Draw(m).polygon([(x / SCALE, y / SCALE) for x, y in pts], fill=1)
    a = np.asarray(m, dtype=bool)
    ys, xs = np.nonzero(a)
    if len(xs) < 10:
        return None
    cov = np.cov(np.stack([xs, ys]))
    ev, evec = np.linalg.eigh(cov)
    elong = float(np.sqrt(ev[1] / max(ev[0], 1e-6)))
    vx, vy = evec[:, 1]
    tilt = float(np.degrees(np.arctan2(abs(vx), abs(vy))))
    x0, x1, y0 = mw // 3, 2 * mw // 3, mh // 2
    front = float(a[y0:, x0:x1].sum()) / len(xs)
    return elong, tilt, front


def main():
    want = defaultdict(set)
    with open(COUNT_CSV, encoding="utf-8") as f:
        for r in csv.DictReader(f):
            if float(r["front_pct"]) >= 5.0:
                want[(r["part"], r["folder"])].add(r["name"])
    rows, feats = [], []
    for (part, folder), names in sorted(want.items()):
        for xml in glob.glob(os.path.join(RAW, part, folder, "*.xml")):
            for im in ET.parse(xml).getroot().iter("image"):
                if im.get("name") not in names:
                    continue
                w, h = int(im.get("width")), int(im.get("height"))
                types = []
                for p in im.iter("polygon"):
                    if p.get("label") != "braille_guide_blocks":
                        continue
                    pts = [tuple(map(float, q.split(",")))
                           for q in p.get("points").split(";")]
                    ft = poly_features(pts, w, h) if len(pts) >= 3 else None
                    if ft is None or ft[2] < FRONT_T:
                        continue
                    elong, tilt, _ = ft
                    t = "linear" if elong >= ELONG_T and tilt <= TILT_T else "dot"
                    types.append(t)
                    feats.append((elong, tilt, t))
                kinds = set(types)
                # A안: 발 앞 영역이 없으면 점형으로 본다(위 판정표 마지막 줄).
                auto = ("both" if len(kinds) == 2 else next(iter(kinds))) if kinds else "dot"
                rows.append({"part": part, "folder": folder, "name": im.get("name"),
                             "n_front_poly": len(types), "auto": auto})
    with open(OUT, "w", newline="", encoding="utf-8") as f:
        wr = csv.DictWriter(f, fieldnames=list(rows[0]))
        wr.writeheader()
        wr.writerows(rows)
    print(f"기준: elong >= {ELONG_T}, tilt <= {TILT_T}도 -> 선형")
    print(f"사진 {len(rows)}장, 발 앞 영역 {len(feats)}개")
    print("사진별 자동 판정:", dict(Counter(r["auto"] for r in rows)))
    e = np.array([x[0] for x in feats])
    t = np.array([x[1] for x in feats])
    print("elong 분위수(10/25/50/75/90):",
          [round(float(v), 1) for v in np.percentile(e, [10, 25, 50, 75, 90])])
    print("tilt 분위수(10/25/50/75/90):",
          [round(float(v)) for v in np.percentile(t, [10, 25, 50, 75, 90])])
    print("영역별: 가늘고(elong>=3) 세로(tilt<=45)", int(((e >= 3) & (t <= 45)).sum()),
          "/ 가늘고 가로", int(((e >= 3) & (t > 45)).sum()),
          "/ 넓음(elong<3)", int((e < 3).sum()))
    print(f"저장: {OUT}")


if __name__ == "__main__":
    main()
