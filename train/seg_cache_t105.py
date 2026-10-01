"""T105: 노면 분할 9클래스 정답 마스크를 만든다(사진은 T104 캐시를 그대로 쓴다).

원본: aihub_raw/surface/Surface_1~5 (CVAT XML 폴리곤).
사진: train/seg_cache_t104/img/<key>.jpg (569x320, `seg_cache_t104.py`가 만든 것)
출력: train/seg_cache_t105/mask/<key>.png (569x320)
      train/seg_cache_t105/index.csv  (사진별 폴더·클래스별 픽셀 수)

클래스 판정표 (T104 (7) + T105 (2), 사용자 확정 2026-10-01):
  | 원래 라벨 (속성)                                        | 클래스             |
  | 라벨 없는 픽셀                                          | 0 배경             |
  | sidewalk (모든 속성)                                    | 1 인도             |
  | roadway·alley (crosswalk 외 모든 속성), bike_lane       | 2 차도             |
  | roadway·alley (crosswalk)                               | 3 횡단보도         |
  | braille_guide_blocks, 모양 선형                         | 4 점자블록 선형    |
  | braille_guide_blocks, 모양 점형                         | 5 점자블록 점형    |
  | caution_zone (stairs)                                   | 6 계단             |
  | caution_zone (manhole, grating)                         | 7 맨홀·그레이팅    |
  | caution_zone (tree_zone)                                | 8 가로수 구역      |
  | caution_zone (repair_zone)                              | 그리지 않음        |
  0~5는 T104와 같은 번호다(앱 `SurfaceClass`와 호환).
  그리는 순서 (사용자 확정 2026-10-01, T105 Q3 '가'): 인도·차도·횡단보도 → 주의 구역 →
  점자블록. 같은 층 안에서는 CVAT z_order 오름차순.
  표에 없는 라벨·속성이 나오면 멈춘다(임의 판정 금지).

실행: python train/seg_cache_t105.py   (8 프로세스, 이미 있는 마스크는 건너뜀)
"""
import csv
import glob
import os
import sys
import xml.etree.ElementTree as ET
from multiprocessing import Pool

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from braille_type_t104 import ELONG_T, TILT_T, poly_features  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(REPO, "aihub_raw", "surface")
IMG = os.path.join(REPO, "train", "seg_cache_t104", "img")
OUT = os.path.join(REPO, "train", "seg_cache_t105")
W, H = 569, 320
N_CLS = 9
CLASS_NAMES = ["background", "sidewalk", "roadway", "crosswalk",
               "braille_linear", "braille_dot", "stairs", "manhole_grating", "tree_zone"]
KNOWN = {"sidewalk", "roadway", "alley", "bike_lane", "braille_guide_blocks",
         "caution_zone"}
CAUTION = {"stairs": 6, "manhole": 7, "grating": 7, "tree_zone": 8, "repair_zone": None}


def class_of(label, attr, pts, w, h):
    """(층, 클래스) — 층 0 바닥면, 1 주의 구역, 2 점자블록. 그리지 않으면 None."""
    if label not in KNOWN:
        raise RuntimeError(f"판정표에 없는 라벨: {label}")
    if label == "caution_zone":
        if attr not in CAUTION:
            raise RuntimeError(f"판정표에 없는 caution_zone 속성: {attr}")
        c = CAUTION[attr]
        return None if c is None else (1, c)
    if label == "sidewalk":
        return (0, 1)
    if label == "bike_lane":
        return (0, 2)
    if label in ("roadway", "alley"):
        return (0, 3 if attr == "crosswalk" else 2)
    ft = poly_features(pts, w, h) if len(pts) >= 3 else None
    if ft is None:
        return None
    return (2, 4 if ft[0] >= ELONG_T and ft[1] <= TILT_T else 5)


def do_xml(xml):
    part = os.path.basename(os.path.dirname(os.path.dirname(xml)))
    folder = os.path.basename(os.path.dirname(xml))
    rows, missing = [], []
    for im in ET.parse(xml).getroot().iter("image"):
        name = im.get("name")
        if not os.path.exists(os.path.join(RAW, part, folder, name)):
            continue
        key = f"{part}__{folder}__{os.path.splitext(name)[0]}"
        if not os.path.exists(os.path.join(IMG, key + ".jpg")):
            missing.append(key)
            continue
        mp = os.path.join(OUT, "mask", key + ".png")
        w, h = int(im.get("width")), int(im.get("height"))
        if not os.path.exists(mp):
            polys = []
            for p in im.iter("polygon"):
                a = p.find("attribute")
                pts = [tuple(map(float, q.split(",")))
                       for q in p.get("points").split(";")]
                lc = class_of(p.get("label"), a.text if a is not None else None,
                              pts, w, h)
                if lc is None:
                    continue
                polys.append((lc[0], int(p.get("z_order") or 0), lc[1], pts))
            polys.sort(key=lambda t: (t[0], t[1]))
            m = Image.new("L", (W, H), 0)
            d = ImageDraw.Draw(m)
            sx, sy = W / w, H / h
            for _, _, c, pts in polys:
                if len(pts) >= 3:
                    d.polygon([(x * sx, y * sy) for x, y in pts], fill=c)
            m.save(mp)
        cnt = np.bincount(np.asarray(Image.open(mp)).ravel(), minlength=N_CLS)
        rows.append([key, part, folder] + cnt.tolist())
    return rows, missing


def main():
    os.makedirs(os.path.join(OUT, "mask"), exist_ok=True)
    xmls = sorted(glob.glob(os.path.join(RAW, "Surface_*", "*", "*.xml")))
    print(f"XML {len(xmls)}개", flush=True)
    rows, missing = [], []
    with Pool(8) as pool:
        for i, (r, m) in enumerate(pool.imap_unordered(do_xml, xmls), 1):
            rows += r
            missing += m
            if i % 100 == 0:
                print(f"  {i}/{len(xmls)} XML, 사진 {len(rows)}", flush=True)
    if missing:
        raise RuntimeError(f"T104 캐시에 사진 없음 {len(missing)}장 (예: {missing[:3]}) — "
                           "seg_cache_t104.py를 먼저 돌릴 것")
    rows.sort()
    with open(os.path.join(OUT, "index.csv"), "w", newline="", encoding="utf-8") as f:
        wr = csv.writer(f)
        wr.writerow(["key", "part", "folder"] + CLASS_NAMES)
        wr.writerows(rows)
    tot = np.array([r[3:] for r in rows]).sum(0)
    print(f"사진 {len(rows)}장")
    for n, v in zip(CLASS_NAMES, tot):
        print(f"  {n:15s} 픽셀 {v / tot.sum() * 100:5.2f}%  사진 "
              f"{sum(1 for r in rows if r[3 + CLASS_NAMES.index(n)] > 0)}")


if __name__ == "__main__":
    main()
