"""T94(준비): AI Hub Surface Masking → T92 줄무늬 위치 규칙 적용 분포.

프레임마다 XML 폴리곤을 중앙 세로 크롭(810x1080, 폰 3:4) 안에서 래스터화해
  crosswalk(roadway/alley 속성 crosswalk) 마스크의 세로 범위·면적,
  그 위쪽 영역의 sidewalk/braille 비율
을 계산하고 구간(zone)을 매긴다. 결과 CSV + 구간별 대조표.
"""
import csv, glob, os, sys, random
import numpy as np
import xml.etree.ElementTree as ET
from PIL import Image, ImageDraw, ImageFont

ROOT = "aihub_raw/surface/Surface_1"
OUT_CSV = "train/surface_zone_stats.csv"
W, H = 1920, 1080
CW = 810
X0 = (W - CW) // 2
SCALE = 4  # 래스터 해상도 축소(속도)
cw, ch = CW // SCALE, H // SCALE

def poly_mask(polys):
    m = Image.new("L", (cw, ch), 0); d = ImageDraw.Draw(m)
    for pts in polys:
        p = [((x - X0) / SCALE, y / SCALE) for x, y in pts]
        d.polygon(p, fill=1)
    return np.asarray(m, dtype=bool)

def parse_points(s):
    return [tuple(map(float, q.split(","))) for q in s.split(";")]

def zone_of(cw_m, sw_m):
    """T92 규칙(2차, 대조표 보고 조정). y는 크롭 높이 비율(0=위, 1=아래).
      none      : crosswalk 없음
      none_far  : 있으나 작거나 위쪽에만(y_bot<0.6) — 멀리/옆
      approach  : 위~중간을 크게 차지(높이>=0.35, y_bot>=0.6)하되 발 앞(아래 15%)은 아님
      on        : 위(y_top<0.4)부터 발 앞까지
      crossed   : 발 앞에만(y_top>=0.4) + 그 위가 인도/점자블록(>=25%)
      ambiguous : 나머지
    """
    area = cw_m.mean()
    if area == 0:
        return "none", area, None, None
    ys = np.where(cw_m.any(axis=1))[0]
    y_top, y_bot = ys.min() / ch, (ys.max() + 1) / ch
    bottom_band = cw_m[int(ch * 0.85):].mean()
    if area < 0.003 or y_bot < 0.6:
        return "none_far", area, y_top, y_bot
    if bottom_band <= 0.15 and (y_bot - y_top) >= 0.35:
        return "approach", area, y_top, y_bot
    if bottom_band > 0.15 and y_top < 0.4:
        return "on", area, y_top, y_bot
    if bottom_band > 0.05 and y_top >= 0.4:
        above = sw_m[: int(ch * y_top)].mean()
        return ("crossed" if above >= 0.25 else "on_end"), area, y_top, y_bot
    return "ambiguous", area, y_top, y_bot

rows = []
for x in sorted(glob.glob(f"{ROOT}/*/*.xml")):
    folder = os.path.dirname(x)
    root = ET.parse(x).getroot()
    for im in root.iter("image"):
        cw_polys, sw_polys = [], []
        for pg in im.iter("polygon"):
            lab = pg.get("label"); attr = (pg.findtext("attribute") or "").strip()
            pts = parse_points(pg.get("points"))
            if lab in ("roadway", "alley") and attr == "crosswalk":
                cw_polys.append(pts)
            elif lab in ("sidewalk", "braille_guide_blocks"):
                sw_polys.append(pts)
        cw_m = poly_mask(cw_polys) if cw_polys else np.zeros((ch, cw), bool)
        sw_m = poly_mask(sw_polys) if sw_polys else np.zeros((ch, cw), bool)
        z, area, yt, yb = zone_of(cw_m, sw_m)
        rows.append({"file": os.path.join(folder, im.get("name")).replace("\\", "/"),
                     "zone": z, "cw_area": round(float(area), 4),
                     "y_top": "" if yt is None else round(yt, 3),
                     "y_bot": "" if yb is None else round(yb, 3),
                     "sidewalk_area": round(float(sw_m.mean()), 4)})
with open(OUT_CSV, "w", encoding="utf-8", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)
from collections import Counter
c = Counter(r["zone"] for r in rows)
print(f"프레임 {len(rows)}장:", dict(c.most_common()))

# 구간별 대조표(무작위 30장, 크롭 영역 표시)
random.seed(0)
font = ImageFont.truetype("C:/Windows/Fonts/arialbd.ttf", 22)
outdir = os.environ.get("SHEET_DIR", "C:/Users/박수홍/AppData/Local/Temp/claude/C--vibecoding-crossWalk/024d14e5-f0bf-443d-bf4a-413b0361aa2b/scratchpad/surface_zones")
os.makedirs(outdir, exist_ok=True)
for z in c:
    fs = [r for r in rows if r["zone"] == z]
    smp = random.sample(fs, min(30, len(fs)))
    TW, TH, C = 320, 180, 6
    R = (len(smp) + C - 1) // C
    sheet = Image.new("RGB", (TW * C, TH * R), "black"); d = ImageDraw.Draw(sheet)
    for i, r in enumerate(smp):
        x, y = (i % C) * TW, (i // C) * TH
        im = Image.open(r["file"]).convert("RGB").resize((TW, TH)); sheet.paste(im, (x, y))
        cx0 = x + int(X0 / W * TW); cx1 = x + int((X0 + CW) / W * TW)
        d.rectangle([cx0, y, cx1, y + TH - 1], outline="yellow", width=1)
        t = f"{i+1} {r['y_top']}-{r['y_bot']}"
        d.rectangle([x, y, x + 8 + 11 * len(t), y + 26], fill="black"); d.text((x + 3, y + 1), t, fill="yellow", font=font)
    sheet.save(f"{outdir}/zone_{z}.jpg", quality=75)
print("대조표:", outdir)
