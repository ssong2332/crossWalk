"""T104: AI Hub Surface 1~5에서 점자블록(braille_guide_blocks) 사진 수를 센다.

판정 기준 (영역은 CVAT 폴리곤을 1/8 크기 마스크로 그려 계산):
  | 항목             | 조건                                                          |
  | 점자블록 있음    | braille_guide_blocks 폴리곤이 1개 이상                        |
  | 면적 1% 이상     | 점자블록 마스크 면적 >= 화면의 1%                              |
  | 앞쪽에 있음      | 가로 가운데 1/3 × 세로 아래 1/2 영역 안 점자블록 >= 그 영역의 5% |
                     (가슴 착용 카메라에서 '발 앞'에 해당한다고 보는 영역 — 추정)
  | 파손             | 폴리곤 attribute == damaged                                   |
  | 차도·인도 동시    | 같은 사진에 roadway(또는 alley)와 sidewalk가 함께 있음          |
세션 다양성은 폴더(Surface_NNN) 수로 센다 — 같은 폴더 사진은 연속 촬영이다.

출력: train/braille_count_t104.csv (사진별), 표준출력 요약.
실행: python train/count_braille_t104.py
"""
import csv
import glob
import os
import xml.etree.ElementTree as ET
from collections import Counter

from PIL import Image, ImageDraw

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(REPO, "aihub_raw", "surface")
OUT = os.path.join(REPO, "train", "braille_count_t104.csv")
SCALE = 8  # 1920x1080 -> 240x135 마스크

rows = []
for part in sorted(os.listdir(RAW)):
    for xml in sorted(glob.glob(os.path.join(RAW, part, "*", "*.xml"))):
        folder = os.path.basename(os.path.dirname(xml))
        for im in ET.parse(xml).getroot().iter("image"):
            w, h = int(im.get("width")), int(im.get("height"))
            mw, mh = w // SCALE, h // SCALE
            mask = Image.new("L", (mw, mh), 0)
            d = ImageDraw.Draw(mask)
            labels, n_poly, damaged = set(), 0, 0
            for p in im.iter("polygon"):
                lab = p.get("label")
                labels.add(lab)
                if lab != "braille_guide_blocks":
                    continue
                n_poly += 1
                a = p.find("attribute")
                damaged += a is not None and a.text == "damaged"
                pts = [tuple(float(v) / SCALE for v in q.split(","))
                       for q in p.get("points").split(";")]
                if len(pts) >= 3:
                    d.polygon(pts, fill=255)
            px = mask.load()
            total = sum(1 for y in range(mh) for x in range(mw) if px[x, y])
            x0, x1, y0 = mw // 3, 2 * mw // 3, mh // 2
            front = sum(1 for y in range(y0, mh) for x in range(x0, x1) if px[x, y])
            front_area = (x1 - x0) * (mh - y0)
            rows.append({
                "part": part, "folder": folder, "name": im.get("name"),
                "n_braille_poly": n_poly, "n_damaged": damaged,
                "area_pct": round(total / (mw * mh) * 100, 2),
                "front_pct": round(front / front_area * 100, 2),
                "has_roadway": int("roadway" in labels or "alley" in labels),
                "has_sidewalk": int("sidewalk" in labels),
            })

with open(OUT, "w", newline="", encoding="utf-8") as f:
    wr = csv.DictWriter(f, fieldnames=list(rows[0]))
    wr.writeheader()
    wr.writerows(rows)

has = [r for r in rows if r["n_braille_poly"] > 0]
big = [r for r in has if r["area_pct"] >= 1.0]
front = [r for r in has if r["front_pct"] >= 5.0]
dmg = [r for r in has if r["n_damaged"] > 0]
both = [r for r in has if r["has_roadway"] and r["has_sidewalk"]]
print(f"전체 사진 {len(rows)} / 폴더 {len({r['folder'] for r in rows})}")
for name, sel in [("점자블록 있음", has), ("면적 1% 이상", big),
                  ("앞쪽(가운데 아래) 5% 이상", front), ("파손 포함", dmg),
                  ("차도·인도 동시", both)]:
    print(f"{name}: {len(sel)}장 ({len(sel)/len(rows)*100:.1f}%), "
          f"폴더 {len({r['folder'] for r in sel})}개")
print("묶음별 점자블록 있음:",
      dict(sorted(Counter(r["part"] for r in has).items())))
print("묶음별 앞쪽 5% 이상:",
      dict(sorted(Counter(r["part"] for r in front).items())))
per = Counter(r["folder"] for r in front)
print("앞쪽 사진이 가장 많은 폴더 상위 5:", per.most_common(5))
print(f"저장: {OUT}")
