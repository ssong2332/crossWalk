"""T90: AI Hub 인도보행 영상 샘플을 **0_none 후보**로 거르는 라벨링 도구.

배경 (2026-09-14):
  AI Hub "인도보행 영상" 샘플(bbox 296 + polygon 99 + depth left 8 = 401장)은
  라벨(XML)이 보행 장애물 29종뿐이라 crosswalk/braille 라벨이 **없다**
  (bbox_sample.xml·polygon_sample.xml 전수 grep 0건). 사진에는 횡단보도가
  배경으로 찍힌 것이 약 10%(대조표 3장 육안, 추정) 있으므로, 사람이
  "횡단보도가 보이는가"만 걸러 나머지를 0_none 학습 데이터로 쓴다.

  왜 none만인가: 실기기 오검출(#2 담장 인도, #10 건넌 직후, 노트북 #7 벽돌
  보도)이 전부 "횡단보도 없는데 approach/front"였고, 누수 없는 CV에서
  none->approach 6.0%, none->front/left/right 3.6%다. 이 세트는 인도·점자블록
  ·골목 장면이 다양해 none 보강에 맞는다. approach/front/left/right는 1~2장
  뿐이라 쓰지 않는다.

규칙 (이 규칙 하나로만 매긴다): **"횡단보도 줄무늬가 보이는가, 보이면 내 경로인가"**
    1 = 안 보임                          -> none (확실)
    2 = 보이지만 내 경로 아님(옆·건너편)  -> none 후보 (CV에서 넣고/빼고 비교)
    3 = 내 앞 경로에 있음(건너려면 저리로) -> approach 후보
    S = 판단 불가                        -> 제외
  정지선·차선·노란선·점자블록만 있는 것은 1이다.
  2와 3을 나누는 이유(2026-09-14, 사용자 지적): 앱은 "건너는 중"을 판단하므로
  옆·건너편 횡단보도는 none이 맞다. 다만 기존 0_none 251장에 그런 장면이
  있는지 미확인이라, 넣었을 때 approach 재현율이 떨어질지는 실측으로 정한다.

저장: train/aihub_none_labels.csv 에 한 줄씩 즉시 append (중간에 꺼도 안전).
  다시 실행하면 이미 매긴 파일은 건너뛴다. Z로 직전 것을 되돌릴 수 있다.

다음 단계(별도 스크립트): 1(또는 1+2)로 매긴 사진을 중앙 세로 크롭(608x1080,
  폰 세로 비율)해 image_extra/0_none_aihub/ 에 두고, 누수 없는 CV에서
  **학습 전용**으로만 쓴다(평가는 자체 사진으로만). (a) 1만 / (b) 1+2 두
  실험을 돌려 none->approach 오검출과 approach 재현율을 나란히 비교한다.

실행:
    python train/label_aihub_none.py [샘플 폴더]
  기본 폴더: C:/Users/박수홍/Downloads/2019-01-004.인도보행영상_sample
"""

import csv
import glob
import os
import sys
import tkinter as tk
from tkinter import messagebox

from PIL import Image, ImageTk

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SRC = r"C:\Users\박수홍\Downloads\2019-01-004.인도보행영상_sample"
OUT_CSV = os.path.join(REPO, "train", "aihub_none_labels.csv")

VIEW_MAX_W = 1280  # 가로 사진이라 폭 기준

CHOICES = [
    ("1", "none", "1  안 보임"),
    ("2", "none_cw_visible", "2  보이지만 내 경로 아님"),
    ("3", "approach", "3  내 앞 경로에 있음"),
]


def collect_targets(src):
    files = (sorted(glob.glob(os.path.join(src, "bbox", "*.jpg")))
             + sorted(glob.glob(os.path.join(src, "polygon", "*.jpg")))
             + sorted(glob.glob(os.path.join(src, "depth", "*_left.png"))))
    # (상대경로, 절대경로) — CSV에는 샘플 폴더 기준 상대경로를 적는다.
    return [(os.path.relpath(p, src).replace("\\", "/"), p) for p in files]


def load_done():
    if not os.path.exists(OUT_CSV):
        return set()
    with open(OUT_CSV, encoding="utf-8") as f:
        return {r["file"] for r in csv.DictReader(f)}


def ensure_csv():
    if not os.path.exists(OUT_CSV):
        with open(OUT_CSV, "w", encoding="utf-8", newline="") as f:
            csv.writer(f).writerow(["file", "label", "status"])


class Labeler:
    def __init__(self, root, targets):
        self.root = root
        self.targets = targets
        self.idx = 0
        self.photo = None

        root.title("AI Hub 샘플 — 횡단보도 보임/안 보임 (T90)")

        self.info = tk.Label(root, font=("Malgun Gothic", 11), anchor="w",
                             justify="left")
        self.info.pack(fill="x", padx=8, pady=(6, 0))

        help_text = (
            "규칙: 「횡단보도 줄무늬가 보이는가, 보이면 내 경로인가」\n"
            "1=안 보임   2=보이지만 내 경로 아님(옆·건너편)   "
            "3=내 앞 경로에 있음   S=판단 불가   Z=이전으로   Q=종료\n"
            "정지선·차선·노란선·점자블록만 있으면 1"
        )
        tk.Label(root, text=help_text, font=("Malgun Gothic", 9),
                 fg="#333", anchor="w", justify="left").pack(
            fill="x", padx=8, pady=(2, 4))

        self.canvas = tk.Canvas(root, bg="black", highlightthickness=0)
        self.canvas.pack()

        for key, value, _ in CHOICES:
            root.bind(key, lambda e, v=value: self.choose(v))
        for k in ("s", "S"):
            root.bind(k, lambda e: self.skip())
        for k in ("z", "Z"):
            root.bind(k, lambda e: self.prev())
        for k in ("q", "Q"):
            root.bind(k, lambda e: self.quit())

        self.show()

    def show(self):
        if self.idx >= len(self.targets):
            messagebox.showinfo("완료", "모든 이미지를 처리했습니다.")
            self.root.quit()
            return

        rel, path = self.targets[self.idx]
        # AI Hub 사진은 EXIF 회전이 없는 가로 1920x1080이라 exif_transpose 불필요.
        im = Image.open(path).convert("RGB")
        im.thumbnail((VIEW_MAX_W, VIEW_MAX_W))
        self.photo = ImageTk.PhotoImage(im)

        self.canvas.config(width=im.size[0], height=im.size[1])
        self.canvas.delete("all")
        self.canvas.create_image(0, 0, anchor="nw", image=self.photo)
        self._draw_scale(im.size[0], im.size[1])

        self.info.config(text=f"[{self.idx + 1}/{len(self.targets)}]  {rel}")

    def _draw_scale(self, w, h):
        y = h - 40
        n = len(CHOICES)
        for i, (_, _, text) in enumerate(CHOICES):
            cx = w * (i + 0.5) / n
            self.canvas.create_rectangle(
                cx - w / (n * 2) + 4, y - 16, cx + w / (n * 2) - 4, y + 16,
                fill="#000000", outline="#FFD60A", width=2)
            self.canvas.create_text(
                cx, y, text=text,
                fill="#FFD60A", font=("Malgun Gothic", 11, "bold"))

    def write_row(self, status, label=""):
        rel, _ = self.targets[self.idx]
        with open(OUT_CSV, "a", encoding="utf-8", newline="") as f:
            csv.writer(f).writerow([rel, label, status])

    def choose(self, value):
        self.write_row("ok", value)
        self.advance()

    def skip(self):
        self.write_row("skipped")
        self.advance()

    def advance(self):
        self.idx += 1
        self.show()

    def prev(self):
        if self.idx == 0:
            return
        self.idx -= 1
        self._drop_last_csv_row()
        self.show()

    @staticmethod
    def _drop_last_csv_row():
        with open(OUT_CSV, "r", encoding="utf-8", newline="") as f:
            lines = f.readlines()
        if len(lines) > 1:
            with open(OUT_CSV, "w", encoding="utf-8", newline="") as f:
                f.writelines(lines[:-1])

    def quit(self):
        self.root.quit()


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SRC
    if not os.path.isdir(src):
        print(f"샘플 폴더를 찾을 수 없습니다: {src}")
        return 1

    ensure_csv()
    done = load_done()
    all_targets = collect_targets(src)
    targets = [t for t in all_targets if t[0] not in done]

    print(f"대상 총 {len(all_targets)}장 중 이미 완료 {len(done)}장 "
          f"-> 남은 {len(targets)}장")
    if not targets:
        print("모두 라벨링되었습니다.")
        return 0

    root = tk.Tk()
    Labeler(root, targets)
    root.mainloop()

    done_after = load_done()
    print(f"저장 완료: {OUT_CSV}  (누적 {len(done_after)}장)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
