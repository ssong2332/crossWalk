"""T104: 노면 분할 학습용 캐시(이미지 + 정답 마스크)를 만든다.

원본: aihub_raw/surface/Surface_1~5 (1920x1080 JPEG + CVAT XML 폴리곤).
출력: train/seg_cache_t104/{img,mask}/<part>__<folder>__<name>.{jpg,png} (569x320)
      train/seg_cache_t104/index.csv  (사진별 폴더·클래스별 픽셀 수)

클래스 판정표 (사용자 확정 2026-09-28, docs/Tasks.md T104 (7)):
  | 원래 라벨 (속성)                                        | 클래스          |
  | 라벨 없는 픽셀                                          | 0 배경          |
  | sidewalk (모든 속성)                                    | 1 인도          |
  | roadway·alley (crosswalk 외 모든 속성), bike_lane       | 2 차도          |
  | roadway·alley (crosswalk)                               | 3 횡단보도      |
  | braille_guide_blocks, 모양 선형                         | 4 점자블록 선형 |
  | braille_guide_blocks, 모양 점형                         | 5 점자블록 점형 |
  | caution_zone                                            | 그리지 않음     |
  선형/점형은 `braille_type_t104.poly_features` + 같은 기준(ELONG_T, TILT_T)으로
  영역마다 판정한다(발 앞 영역 표본 검수 98%, 그 밖 영역은 미검증).
  그리는 순서: CVAT z_order 오름차순, 점자블록은 맨 마지막(맨 위).
  표에 없는 라벨이 나오면 멈춘다(임의 판정 금지).

실행: python train/seg_cache_t104.py   (8 프로세스, 이미 있는 파일은 건너뜀)
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
OUT = os.path.join(REPO, "train", "seg_cache_t104")
W, H = 569, 320
N_CLS = 6
CLASS_NAMES = ["background", "sidewalk", "roadway", "crosswalk",
               "braille_linear", "braille_dot"]
KNOWN = {"sidewalk", "roadway", "alley", "bike_lane", "braille_guide_blocks",
         "caution_zone"}


def class_of(label, attr, pts, w, h):
    if label not in KNOWN:
        raise RuntimeError(f"판정표에 없는 라벨: {label}")
    if label == "caution_zone":
        return None
    if label == "sidewalk":
        return 1
    if label == "bike_lane":
        return 2
    if label in ("roadway", "alley"):
        return 3 if attr == "crosswalk" else 2
    ft = poly_features(pts, w, h) if len(pts) >= 3 else None
    if ft is None:
        return None
    return 4 if ft[0] >= ELONG_T and ft[1] <= TILT_T else 5


def do_xml(xml):
    part = os.path.basename(os.path.dirname(os.path.dirname(xml)))
    folder = os.path.basename(os.path.dirname(xml))
    rows = []
    for im in ET.parse(xml).getroot().iter("image"):
        name = im.get("name")
        key = f"{part}__{folder}__{os.path.splitext(name)[0]}"
        ip = os.path.join(OUT, "img", key + ".jpg")
        mp = os.path.join(OUT, "mask", key + ".png")
        src = os.path.join(RAW, part, folder, name)
        if not os.path.exists(src):
            continue
        w, h = int(im.get("width")), int(im.get("height"))
        if not os.path.exists(mp):
            polys = []
            for p in im.iter("polygon"):
                a = p.find("attribute")
                pts = [tuple(map(float, q.split(",")))
                       for q in p.get("points").split(";")]
                c = class_of(p.get("label"), a.text if a is not None else None,
                             pts, w, h)
                if c is None:
                    continue
                z = int(p.get("z_order") or 0)
                polys.append((1 if c >= 4 else 0, z, c, pts))
            polys.sort(key=lambda t: (t[0], t[1]))
            m = Image.new("L", (W, H), 0)
            d = ImageDraw.Draw(m)
            sx, sy = W / w, H / h
            for _, _, c, pts in polys:
                if len(pts) >= 3:
                    d.polygon([(x * sx, y * sy) for x, y in pts], fill=c)
            m.save(mp)
        if not os.path.exists(ip):
            Image.open(src).convert("RGB").resize((W, H), Image.BILINEAR).save(ip, quality=90)
        cnt = np.bincount(np.asarray(Image.open(mp)).ravel(), minlength=N_CLS)
        rows.append([key, part, folder] + cnt.tolist())
    return rows


def main():
    os.makedirs(os.path.join(OUT, "img"), exist_ok=True)
    os.makedirs(os.path.join(OUT, "mask"), exist_ok=True)
    xmls = sorted(glob.glob(os.path.join(RAW, "Surface_*", "*", "*.xml")))
    print(f"XML {len(xmls)}개", flush=True)
    rows = []
    with Pool(8) as pool:
        for i, r in enumerate(pool.imap_unordered(do_xml, xmls), 1):
            rows += r
            if i % 50 == 0:
                print(f"  {i}/{len(xmls)} XML, 사진 {len(rows)}", flush=True)
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
