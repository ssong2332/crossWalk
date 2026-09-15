"""T92: 1_approach 사진을 "줄무늬가 화면 어디에 있는가"로 재분류하는 도구.

배경 (2026-09-15, 사용자 확정 정의):
  | 상황            | 화면                                        | 라벨              |
  | 앞에 횡단보도    | 줄무늬가 화면 위쪽, 발 앞은 인도/차도 가장자리 | approach (유지)   |
  | 건너는 중        | 줄무늬가 화면 전체(발 앞부터 위까지)          | front/left/right  |
  | 다 건넘          | 줄무늬가 맨 아래에만, 앞엔 점자블록·볼라드    | none              |
  | 없음/멀리 작게   | 줄무늬 없음 또는 위쪽에 작게만               | none              |
  "건너기 끝 직전"은 보수적으로: 줄무늬가 아직 아래 절반쯤 차지하면 건너는 중,
  맨 아래 띠만 남으면 다 건넘.

  왜: 실기기 #21(멀리 보이는데 "앞에 횡단보도"), #10(건넌 직후인데 "앞에
  횡단보도"). 앱의 "건넜습니다"는 (front/left/right)→none 전이로 나므로
  (feedback_service.dart:219) 건넌 직후는 none이어야 한다.

키:
    1 = 앞에 횡단보도 (approach 유지)
    2 = 위쪽에 작게만 / 멀리        -> none으로 이동
    3 = 줄무늬가 전체 (건너는 중)   -> 위 클래스 후보 (각도 라벨 필요, 별도 처리)
    4 = 다 건넘 (맨 아래만 + 인도) -> none으로 이동
    S = 판단 불가   Z = 이전   Q = 종료
저장: train/approach_zone_labels.csv (즉시 append, 재실행 시 이어서).
이 스크립트는 **기록만** 한다. 실제 폴더 이동은 결과를 보고 따로 한다.
"""

import csv
import os
import sys
import tkinter as tk
from tkinter import messagebox

from PIL import Image, ImageOps, ImageTk

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# T92 확장: 인자로 클래스 폴더를 주면 그 폴더를 같은 규칙으로 매긴다.
#   python train/label_approach_zone.py            -> 1_approach, approach_zone_labels.csv
#   python train/label_approach_zone.py 2_front    -> image/2_front, zone_labels_2_front.csv
# 사용자 지적(2026-09-15): front/left/right에도 "다 건넘" 장면이 섞여 있을 수 있다.
CLASS_DIR = sys.argv[1] if len(sys.argv) > 1 else "1_approach"
SRC_DIR = os.path.join(REPO, "image", CLASS_DIR)
OUT_CSV = os.path.join(REPO, "train",
                       "approach_zone_labels.csv" if CLASS_DIR == "1_approach"
                       else f"zone_labels_{CLASS_DIR}.csv")
VIEW_MAX = 820

CHOICES = [
    ("1", "approach", "1  앞에 (위쪽) → 유지"),
    ("2", "far_none", "2  멀리 작게 → none"),
    ("3", "on_crosswalk", "3  전체 (건너는 중)"),
    ("4", "crossed_none", "4  다 건넘 (아래만) → none"),
]


def collect_targets():
    return sorted(f for f in os.listdir(SRC_DIR)
                  if f.lower().endswith((".jpg", ".jpeg", ".png")))


def load_done():
    if not os.path.exists(OUT_CSV):
        return set()
    with open(OUT_CSV, encoding="utf-8") as f:
        return {r["file"] for r in csv.DictReader(f)}


def ensure_csv():
    if not os.path.exists(OUT_CSV):
        with open(OUT_CSV, "w", encoding="utf-8", newline="") as f:
            csv.writer(f).writerow(["file", "zone", "status"])


class Labeler:
    def __init__(self, root, targets):
        self.root, self.targets, self.idx, self.photo = root, targets, 0, None
        root.title(f"{CLASS_DIR} 재분류 — 줄무늬 위치 (T92)")
        self.info = tk.Label(root, font=("Malgun Gothic", 11), anchor="w", justify="left")
        self.info.pack(fill="x", padx=8, pady=(6, 0))
        tk.Label(root, text=(
            "규칙: 「줄무늬가 화면 어디에 있는가」\n"
            "1=위쪽(앞에 횡단보도, 유지)   2=멀리 작게만(→none)   "
            "3=전체(건너는 중)   4=맨 아래만+인도(다 건넘, →none)\n"
            "끝 직전이 애매하면: 아래 절반쯤 차지=3, 맨 아래 띠만=4.   S=불가  Z=이전  Q=종료"
        ), font=("Malgun Gothic", 9), fg="#333", anchor="w", justify="left").pack(
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
        name = self.targets[self.idx]
        im = ImageOps.exif_transpose(Image.open(os.path.join(SRC_DIR, name))).convert("RGB")
        im.thumbnail((VIEW_MAX, VIEW_MAX))
        self.photo = ImageTk.PhotoImage(im)
        self.canvas.config(width=im.size[0], height=im.size[1])
        self.canvas.delete("all")
        self.canvas.create_image(0, 0, anchor="nw", image=self.photo)
        w, h = im.size
        # 화면 3등분 눈금 — "위쪽/전체/아래만" 판단 보조
        for frac in (1 / 3, 2 / 3):
            self.canvas.create_line(0, h * frac, w, h * frac, fill="#FFD60A", dash=(6, 6))
        y = h - 40
        n = len(CHOICES)
        for i, (_, _, text) in enumerate(CHOICES):
            cx = w * (i + 0.5) / n
            self.canvas.create_rectangle(cx - w / (n * 2) + 3, y - 16, cx + w / (n * 2) - 3, y + 16,
                                         fill="#000000", outline="#FFD60A", width=2)
            self.canvas.create_text(cx, y, text=text, fill="#FFD60A",
                                    font=("Malgun Gothic", 9, "bold"))
        self.info.config(text=f"[{self.idx + 1}/{len(self.targets)}]  {CLASS_DIR}/{name}")

    def write_row(self, status, zone=""):
        with open(OUT_CSV, "a", encoding="utf-8", newline="") as f:
            csv.writer(f).writerow([self.targets[self.idx], zone, status])

    def choose(self, v):
        self.write_row("ok", v); self.idx += 1; self.show()

    def skip(self):
        self.write_row("skipped"); self.idx += 1; self.show()

    def prev(self):
        if self.idx == 0:
            return
        self.idx -= 1
        with open(OUT_CSV, "r", encoding="utf-8", newline="") as f:
            lines = f.readlines()
        if len(lines) > 1:
            with open(OUT_CSV, "w", encoding="utf-8", newline="") as f:
                f.writelines(lines[:-1])
        self.show()

    def quit(self):
        self.root.quit()


def main():
    ensure_csv()
    done = load_done()
    targets = [t for t in collect_targets() if t not in done]
    print(f"대상 {len(collect_targets())}장 중 완료 {len(done)}장 -> 남은 {len(targets)}장")
    if not targets:
        print("모두 라벨링되었습니다.")
        return 0
    root = tk.Tk()
    Labeler(root, targets)
    root.mainloop()
    print(f"저장: {OUT_CSV} (누적 {len(load_done())}장)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
