"""T159: 반대 방향 오판 사진 시트 — 원본 + 라벨 선(초록) + 예측 방향(빨강, 묶인 fold 문턱 2단계 B=27.5).

    python train/t159_opp_sheet.py   -> train/t159/opp_sheet.jpg, train/t159/opp_list.csv
대상: ord224 순서형|각|·회귀부호 단일·반전 TTA에서 반대 방향으로 센 사진(합집합).
"""
import csv, math, sys
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageOps

sys.path.insert(0, str(Path(__file__).resolve().parent))
import t159_report as r  # noqa: E402
import t159_level_eval as ev  # noqa: E402

DATA = Path("C:/vibecoding/crossWalk")
OUT = Path(__file__).resolve().parent / "t159"
LAB = {}
for fn in ["angle_labels.csv", "angle_labels_t150_main.csv", "angle_labels_t150_pilot.csv"]:
    with open(DATA / "train" / fn, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            LAB.setdefault((row["class"], row["filename"]), row)

hits = {}
for sc, nm in [("ord_reg_plain", "단일"), ("ord_reg_tta", "TTA")]:
    d = r.from_t159("ord224", sc)
    _, score = ev.nested(d, (12, 27.5), ev.TUNE_STRAIGHT_REF)
    bad = (np.abs(d["gt"]) >= 12) & (np.abs(score) >= 12) & (np.sign(d["gt"]) != np.sign(score))
    for i in np.where(bad)[0]:
        h = hits.setdefault(d["key"][i], {"src": d["src"][i], "gt": d["gt"][i], "pr": {}})
        h["pr"][nm] = d["pr"][i]

font = ImageFont.truetype("C:/Windows/Fonts/malgun.ttf", 18)
W, H = 360, 480
tiles = []
rows = []
for n, (k, h) in enumerate(hits.items(), 1):
    cls, fn = k
    p = DATA / ("image" if h["src"] == "existing" else "train") / cls / fn
    im = ImageOps.exif_transpose(Image.open(p)).convert("RGB")
    if h["src"] == "t150" and im.width > im.height:
        im = im.rotate(-90, expand=True)  # 센서 방향 -> 화면 방향(라벨 도구·학습과 같음, t151:188)
    L = LAB[k]
    im = im.resize((W, H))
    dr = ImageDraw.Draw(im)
    has_line = bool(L["view_w"])
    if has_line:  # 라벨 선 좌표가 비어 있는 행이 있다(각도만 있음)
        x1, y1, x2, y2 = (float(L[c]) for c in ("x1", "y1", "x2", "y2"))
        s = W / float(L["view_w"]), H / float(L["view_h"])
        dr.line([(x1 * s[0], y1 * s[1]), (x2 * s[0], y2 * s[1])], fill=(0, 230, 0), width=4)
    pr = h["pr"].get("TTA", h["pr"].get("단일"))
    a = math.radians(pr)
    bx, by = W / 2, H - 20
    dr.line([(bx, by), (bx + 200 * math.sin(a), by - 200 * math.cos(a))], fill=(255, 40, 40), width=4)
    txt = f"#{n} {cls}/{fn}\n정답 {h['gt']:+.1f}°  " + "  ".join(f"{m} {v:+.1f}°" for m, v in h["pr"].items()) + ("" if has_line else "  (라벨 선 없음)")
    dr.rectangle([0, 0, W, 46], fill=(0, 0, 0))
    dr.multiline_text((4, 2), txt, font=ImageFont.truetype("C:/Windows/Fonts/malgun.ttf", 15), fill=(255, 255, 255))
    tiles.append(im)
    rows.append([n, h["src"], cls, fn, f"{h['gt']:.1f}", *(f"{h['pr'].get(m, float('nan')):.1f}" for m in ("단일", "TTA"))])

C = 4
sheet = Image.new("RGB", (C * W, math.ceil(len(tiles) / C) * H), "white")
for i, t in enumerate(tiles):
    sheet.paste(t, ((i % C) * W, (i // C) * H))
sheet.save(OUT / "opp_sheet.jpg", quality=88)
with open(OUT / "opp_list.csv", "w", encoding="utf-8", newline="") as f:
    w = csv.writer(f)
    w.writerow(["no", "src", "class", "filename", "gt_deg", "pred_plain_deg", "pred_tta_deg"])
    w.writerows(rows)
print(len(rows), "장")
for x in rows:
    print(x)
