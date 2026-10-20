"""T105: AI Hub Surface 1~5에서 주의 구역(caution_zone) 수를 속성별로 센다.

판정 기준 (영역은 CVAT 폴리곤을 192x108 마스크로 그려 계산):
  | 항목               | 조건                                                            |
  | 폴리곤             | label == caution_zone (사진 파일이 있는 것만)                    |
  | 속성               | 폴리곤 attribute (stairs/manhole/tree_zone/grating/repair_zone)  |
  | 면적               | 폴리곤 마스크 면적 / 화면                                        |
  | 발 앞 칸 5% 이상   | 가로 가운데 1/3 × 세로 아래 1/2 영역 안 폴리곤 >= 그 영역의 5%    |
                       (가로 원본 기준 근사 — 앱은 세로 영역을 본다, 추정)
세션 다양성은 폴더(Surface_NNN) 수로 센다.

클래스 판정표 (사용자 확정 2026-10-01, 제안안 그대로, docs/Tasks.md T105 (2)):
  | 속성                | 클래스                  |
  | stairs              | 새 클래스: 계단          |
  | manhole, grating    | 새 클래스: 맨홀·그레이팅 |
  | tree_zone           | 새 클래스: 가로수 구역   |
  | repair_zone         | 그리지 않음(데이터 부족) |

출력: train/caution_count_t105.json (속성별 요약), 표준출력 요약.
실행: python train/count_caution_t105.py   (8 프로세스)
"""
import collections
import glob
import json
import os
import xml.etree.ElementTree as ET
from multiprocessing import Pool

import numpy as np
from PIL import Image, ImageDraw

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(REPO, "aihub_raw", "surface")
OUT = os.path.join(REPO, "train", "caution_count_t105.json")
GW, GH = 192, 108


def do_xml(xml):
    part = os.path.basename(os.path.dirname(os.path.dirname(xml)))
    folder = os.path.basename(os.path.dirname(xml))
    out = []
    for im in ET.parse(xml).getroot().iter("image"):
        name = im.get("name")
        if not os.path.exists(os.path.join(RAW, part, folder, name)):
            continue
        w, h = int(im.get("width")), int(im.get("height"))
        for p in im.iter("polygon"):
            if p.get("label") != "caution_zone":
                continue
            a = p.find("attribute")
            attr = a.text if a is not None else None
            pts = [tuple(map(float, q.split(","))) for q in p.get("points").split(";")]
            if len(pts) < 3:
                out.append((part, folder, name, attr, 0.0, 0.0))
                continue
            m = Image.new("L", (GW, GH), 0)
            ImageDraw.Draw(m).polygon([(x * GW / w, y * GH / h) for x, y in pts], fill=1)
            mask = np.asarray(m, dtype=bool)
            front = mask[GH // 2:, GW // 3: 2 * GW // 3].mean()
            out.append((part, folder, name, attr, float(mask.mean()), float(front)))
    return out


def main():
    xmls = sorted(glob.glob(os.path.join(RAW, "Surface_*", "*", "*.xml")))
    rows = []
    with Pool(8) as pool:
        for r in pool.imap_unordered(do_xml, xmls):
            rows += r
    by = collections.defaultdict(list)
    for r in rows:
        by[r[3]].append(r)
    print(f"XML {len(xmls)}개, caution_zone 폴리곤 {len(rows)}개 (사진 있는 것)")
    print(f"{'속성':12s} {'폴리곤':>7s} {'사진':>6s} {'폴더':>5s} {'면적중앙%':>8s} "
          f"{'앞칸5%↑사진':>10s}  파트별 사진")
    res = {}
    for k in sorted(by, key=lambda k: -len(by[k])):
        rs = by[k]
        imgs = {r[:3] for r in rs}
        folders = {r[:2] for r in rs}
        front_imgs = {r[:3] for r in rs if r[5] >= 0.05}
        parts = collections.Counter(p for p, _, _ in imgs)
        med = float(np.median([r[4] for r in rs])) * 100
        print(f"{str(k):12s} {len(rs):7d} {len(imgs):6d} {len(folders):5d} {med:8.2f} "
              f"{len(front_imgs):10d}  {dict(sorted(parts.items()))}")
        res[str(k)] = dict(polygons=len(rs), images=len(imgs), folders=len(folders),
                           median_area_pct=round(med, 3), front5_images=len(front_imgs),
                           parts=dict(sorted(parts.items())))
    all_imgs = {r[:3] for r in rows}
    front_all = {r[:3] for r in rows if r[5] >= 0.05}
    print(f"caution_zone 있는 사진 합계 {len(all_imgs)}장 / 앞칸 5%↑ {len(front_all)}장")
    res["_total"] = dict(polygons=len(rows), images=len(all_imgs), front5_images=len(front_all))
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(res, f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
