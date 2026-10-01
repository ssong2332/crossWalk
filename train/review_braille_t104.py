"""T104: 점자블록 선형/점형 **자동 분류 검수** 도구 (사용자 결정 3안).

`braille_type_t104.py`가 모양으로 매긴 사진별 자동 판정을 사람이 표본으로
확인한다. 표본은 판정별로 고르게 뽑는다(선형 128 / 점형 127 / 둘 다 전부 /
없음 전부, 합 300장, seed 고정) — 판정별 정확도를 따로 재기 위해서다.

화면: 발 앞 영역(청록 사각형)과 점자블록 영역. 영역 색이 자동 판정이다.
  초록 = 선형(유도, 따라 걷는 띠)   빨강 = 점형(정지·경고)   회색 = 발 앞 아님(판정 제외)

키:
  Enter/Space = 자동 판정이 맞음
  1 = 선형만   2 = 점형만   3 = 둘 다   0 = 점자블록 아님 / 판단 불가
  Z = 이전 장(기록 1줄 취소)   Q = 종료(다시 실행하면 이어서)
판단 기준: **발 앞(청록 사각형) 안에 있는 블록**만 본다.

결과: train/review_t104_braille/type_review_log.csv, 종료 시 판정별 일치율 출력.
실행: python train/review_braille_t104.py
"""
import csv
import glob
import os
import random
import sys
import tkinter as tk
import xml.etree.ElementTree as ET
from collections import Counter

from PIL import Image, ImageDraw, ImageFont, ImageTk

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from braille_type_t104 import ELONG_T, FRONT_T, TILT_T, poly_features  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(REPO, "aihub_raw", "surface")
AUTO_CSV = os.path.join(REPO, "train", "braille_type_auto_t104.csv")
OUT_CSV = os.path.join(REPO, "train", "review_t104_braille", "type_review_log.csv")
VIEW_W, VIEW_H = 1280, 720
PER_CLASS = {"linear": 128, "dot": 127}  # both/none은 전부
NAMES = {"linear": "선형", "dot": "점형", "both": "둘 다", "none": "없음/불가"}
KEYS = {"1": "linear", "2": "dot", "3": "both", "0": "none"}
FIELDS = ["idx", "part", "folder", "name", "auto", "human", "agree"]


def sample_rows():
    with open(AUTO_CSV, encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    rng = random.Random(104)
    out = []
    for cls in ("linear", "dot", "both", "none"):
        grp = [r for r in rows if r["auto"] == cls]
        n = PER_CLASS.get(cls, len(grp))
        out += rng.sample(grp, min(n, len(grp)))
    rng.shuffle(out)
    for i, r in enumerate(out):
        r["idx"] = str(i)
    return out


def load_polys(r):
    for xml in glob.glob(os.path.join(RAW, r["part"], r["folder"], "*.xml")):
        for im in ET.parse(xml).getroot().iter("image"):
            if im.get("name") == r["name"]:
                w, h = int(im.get("width")), int(im.get("height"))
                out = []
                for p in im.iter("polygon"):
                    if p.get("label") != "braille_guide_blocks":
                        continue
                    pts = [tuple(map(float, q.split(",")))
                           for q in p.get("points").split(";")]
                    ft = poly_features(pts, w, h) if len(pts) >= 3 else None
                    if ft is None or ft[2] < FRONT_T:
                        kind = "off"
                    else:
                        kind = "linear" if ft[0] >= ELONG_T and ft[1] <= TILT_T else "dot"
                    out.append((pts, kind))
                return w, h, out
    return 1920, 1080, []


def done_idx():
    if not os.path.exists(OUT_CSV):
        return set()
    with open(OUT_CSV, encoding="utf-8") as f:
        return {r["idx"] for r in csv.DictReader(f)}


def summary():
    if not os.path.exists(OUT_CSV):
        return
    with open(OUT_CSV, encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    print(f"검수 {len(rows)}장")
    for cls in ("linear", "dot", "both", "none"):
        g = [r for r in rows if r["auto"] == cls]
        if g:
            ok = sum(r["agree"] == "1" for r in g)
            print(f"  자동 {NAMES[cls]:5s}: {ok}/{len(g)} 일치 ({ok/len(g)*100:.1f}%)"
                  f"  사람 판정 {dict(Counter(NAMES[r['human']] for r in g))}")


class Reviewer:
    def __init__(self, root, rows):
        self.root, self.rows, self.i = root, rows, 0
        root.title("T104 점자블록 선형/점형 검수 — 맞으면 Enter, 틀리면 1/2/3/0")
        self.info = tk.Label(root, font=("Malgun Gothic", 12, "bold"), anchor="w")
        self.info.pack(fill="x", padx=8, pady=(6, 0))
        tk.Label(root, font=("Malgun Gothic", 9), fg="#333", anchor="w", justify="left",
                 text="초록 = 선형(유도)  빨강 = 점형(정지·경고)  회색 = 발 앞 아님   "
                      "청록 사각형 = 발 앞 영역 (이 안의 블록만 판단)\n"
                      "Enter/Space 자동 판정 맞음   1 선형만   2 점형만   3 둘 다   "
                      "0 점자블록 아님·판단 불가   Z 이전   Q 종료").pack(fill="x", padx=8)
        self.canvas = tk.Label(root)
        self.canvas.pack()
        root.bind("<Return>", lambda e: self.save(None))
        root.bind("<space>", lambda e: self.save(None))
        for k, v in KEYS.items():
            root.bind(k, lambda e, v=v: self.save(v))
        for k in ("z", "Z"):
            root.bind(k, lambda e: self.prev())
        for k in ("q", "Q"):
            root.bind(k, lambda e: root.quit())
        self.font = ImageFont.truetype("malgun.ttf", 22)
        self.show()

    def show(self):
        if self.i >= len(self.rows):
            self.info.config(text="검수 완료 — Q로 종료")
            return
        r = self.rows[self.i]
        w, h, polys = load_polys(r)
        im = Image.open(os.path.join(RAW, r["part"], r["folder"], r["name"])).convert("RGB")
        over = Image.new("RGBA", im.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(over)
        col = {"linear": (0, 220, 0), "dot": (255, 40, 40), "off": (160, 160, 160)}
        for pts, kind in polys:
            c = col[kind]
            d.polygon(pts, fill=c + (70,), outline=c + (255,), width=4)
        im = Image.alpha_composite(im.convert("RGBA"), over).convert("RGB")
        dd = ImageDraw.Draw(im)
        dd.rectangle([w / 3, h / 2, 2 * w / 3, h - 1], outline=(0, 255, 255), width=4)
        im = im.resize((VIEW_W, VIEW_H))
        self.photo = ImageTk.PhotoImage(im)
        self.canvas.config(image=self.photo)
        self.info.config(text=f"[{self.i + 1}/{len(self.rows)}]  자동 판정: {NAMES[r['auto']]}"
                              f"    {r['folder']}/{r['name']}")

    def save(self, human):
        if self.i >= len(self.rows):
            return
        r = self.rows[self.i]
        human = human or r["auto"]
        with open(OUT_CSV, "a", newline="", encoding="utf-8") as f:
            csv.writer(f).writerow([r["idx"], r["part"], r["folder"], r["name"],
                                    r["auto"], human, int(human == r["auto"])])
        self.i += 1
        self.show()

    def prev(self):
        if self.i == 0:
            return
        with open(OUT_CSV, encoding="utf-8") as f:
            lines = f.readlines()
        if len(lines) > 1:
            with open(OUT_CSV, "w", encoding="utf-8", newline="") as f:
                f.writelines(lines[:-1])
        self.i -= 1
        self.show()


def main():
    os.makedirs(os.path.dirname(OUT_CSV), exist_ok=True)
    if not os.path.exists(OUT_CSV):
        with open(OUT_CSV, "w", newline="", encoding="utf-8") as f:
            csv.writer(f).writerow(FIELDS)
    done = done_idx()
    rows = [r for r in sample_rows() if r["idx"] not in done]
    print(f"검수 대상 남은 {len(rows)}장 (완료 {len(done)}장, 기록: {OUT_CSV})")
    if rows:
        root = tk.Tk()
        Reviewer(root, rows)
        root.mainloop()
    summary()
    return 0


if __name__ == "__main__":
    sys.exit(main())
