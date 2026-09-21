"""T101: 미분류 촬영본을 키 하나로 클래스 폴더에 넣는 도구.

배경 (2026-09-21): 사용자가 새로 찍은 사진 212장이 `image/QuickShare_…/`에
그대로 들어왔다. 학습 스크립트는 `image/0_none … 4_right`(+보관 `5_crossed`)만
읽으므로 폴더로 나눠야 학습에 들어간다.

판정표 (T92 정의 그대로 — 줄무늬가 화면 어디에 있는가):
    키   폴더          기준
     0   0_none        줄무늬 없음 / 멀리 작게만 / 옆·건너편 것만 보임
     1   1_approach    줄무늬가 화면 **위쪽**(아직 올라서기 전, 앞에 있음)
     2   2_front       줄무늬가 화면 전체, 줄무늬와 나란히 직진 중
     3   3_left        줄무늬 전체, 왼쪽으로 틀어짐(오른쪽으로 가야 함)
     4   4_right       줄무늬 전체, 오른쪽으로 틀어짐(왼쪽으로 가야 함)
     5   5_crossed     줄무늬가 **맨 아래만** + 앞에 인도·점자블록·볼라드 (다 건넘)
     S   건너뛰기(원래 폴더에 둠)   Z   직전 이동 되돌리기   Q   종료
  표에 없는 장면(예: 횡단보도인지 애매)은 S로 두고 나중에 묻는다.

동작: 키를 누르면 파일을 `image/<폴더>/`로 **이동**하고 `train/class_sort_log.csv`
  (src, filename, class, when)에 한 줄 남긴다. Z는 마지막 이동을 되돌린다.
  같은 이름 파일이 이미 있으면 덮어쓰지 않고 건너뛴 뒤 알린다.

실행:
    python train/label_class.py image/QuickShare_2609210907
"""

import csv
import os
import shutil
import sys
import tkinter as tk
from datetime import datetime
from tkinter import messagebox

from PIL import Image, ImageOps, ImageTk

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMAGE_ROOT = os.path.join(REPO, "image")
LOG_CSV = os.path.join(REPO, "train", "class_sort_log.csv")
VIEW_MAX = 820

CHOICES = [
    ("0", "0_none", "0 없음/멀리"),
    ("1", "1_approach", "1 앞(위쪽)"),
    ("2", "2_front", "2 직진"),
    ("3", "3_left", "3 왼쪽 틀어짐"),
    ("4", "4_right", "4 오른쪽 틀어짐"),
    ("5", "5_crossed", "5 다 건넘(아래만)"),
]


def collect_targets(src):
    return sorted(os.path.join(src, f) for f in os.listdir(src)
                  if f.lower().endswith((".jpg", ".jpeg", ".png")))


def ensure_log():
    if not os.path.exists(LOG_CSV):
        with open(LOG_CSV, "w", encoding="utf-8", newline="") as f:
            csv.writer(f).writerow(["src", "filename", "class", "when"])


class Sorter:
    def __init__(self, root, targets, src):
        self.root, self.targets, self.src, self.idx = root, targets, src, 0
        self.photo = None
        self.undo = []  # (dst_path, src_path)

        root.title("촬영본 클래스 분류 (T101)")
        self.info = tk.Label(root, font=("Malgun Gothic", 11), anchor="w", justify="left")
        self.info.pack(fill="x", padx=8, pady=(6, 0))
        tk.Label(root, text=(
            "줄무늬가 화면 어디에 있는가: 0=없음/멀리  1=위쪽(앞에 있음)  2=전체·직진  "
            "3=전체·왼쪽 틀어짐  4=전체·오른쪽 틀어짐  5=맨 아래만+인도(다 건넘)\n"
            "S=건너뛰기(그대로 둠)   Z=직전 이동 되돌리기   Q=종료"
        ), font=("Malgun Gothic", 9), fg="#333", anchor="w", justify="left").pack(
            fill="x", padx=8, pady=(2, 4))
        self.canvas = tk.Canvas(root, bg="black", highlightthickness=0)
        self.canvas.pack()
        for key, cls, _ in CHOICES:
            root.bind(key, lambda e, c=cls: self.move_to(c))
        for k in ("s", "S"):
            root.bind(k, lambda e: self.advance())
        for k in ("z", "Z"):
            root.bind(k, lambda e: self.undo_last())
        for k in ("q", "Q"):
            root.bind(k, lambda e: root.quit())
        self.show()

    def show(self):
        if self.idx >= len(self.targets):
            messagebox.showinfo("완료", "모든 이미지를 처리했습니다.")
            self.root.quit()
            return
        path = self.targets[self.idx]
        im = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
        im.thumbnail((VIEW_MAX, VIEW_MAX))
        self.photo = ImageTk.PhotoImage(im)
        self.canvas.config(width=im.size[0], height=im.size[1])
        self.canvas.delete("all")
        self.canvas.create_image(0, 0, anchor="nw", image=self.photo)
        w, h = im.size
        # 1/3·2/3 눈금(위쪽/전체/아래만 판단 보조)
        for fr in (1 / 3, 2 / 3):
            self.canvas.create_line(0, h * fr, w, h * fr, fill="#FFD60A", dash=(6, 6))
        y = h - 40
        n = len(CHOICES)
        for i, (_, _, text) in enumerate(CHOICES):
            cx = w * (i + 0.5) / n
            self.canvas.create_rectangle(cx - w / (n * 2) + 3, y - 16, cx + w / (n * 2) - 3, y + 16,
                                         fill="#000000", outline="#FFD60A", width=2)
            self.canvas.create_text(cx, y, text=text, fill="#FFD60A",
                                    font=("Malgun Gothic", 9, "bold"))
        self.info.config(text=f"[{self.idx + 1}/{len(self.targets)}]  {os.path.basename(path)}")

    def move_to(self, cls):
        src = self.targets[self.idx]
        dst_dir = os.path.join(IMAGE_ROOT, cls)
        os.makedirs(dst_dir, exist_ok=True)
        dst = os.path.join(dst_dir, os.path.basename(src))
        if os.path.exists(dst):
            messagebox.showwarning("이름 겹침", f"{cls}/ 에 같은 이름이 이미 있어 옮기지 않았습니다.")
            return
        shutil.move(src, dst)
        self.undo.append((dst, src))
        with open(LOG_CSV, "a", encoding="utf-8", newline="") as f:
            csv.writer(f).writerow([os.path.relpath(self.src, REPO).replace("\\", "/"),
                                    os.path.basename(src), cls,
                                    datetime.now().strftime("%Y-%m-%d %H:%M:%S")])
        self.advance()

    def advance(self):
        self.idx += 1
        self.show()

    def undo_last(self):
        if not self.undo or self.idx == 0:
            return
        dst, src = self.undo.pop()
        shutil.move(dst, src)
        with open(LOG_CSV, "r", encoding="utf-8", newline="") as f:
            lines = f.readlines()
        if len(lines) > 1:
            with open(LOG_CSV, "w", encoding="utf-8", newline="") as f:
                f.writelines(lines[:-1])
        self.idx -= 1
        self.show()


def main():
    if len(sys.argv) < 2 or not os.path.isdir(sys.argv[1]):
        print("사용법: python train/label_class.py <미분류 폴더>")
        return 1
    src = os.path.abspath(sys.argv[1])
    ensure_log()
    targets = collect_targets(src)
    print(f"대상 {len(targets)}장 ({src})")
    if not targets:
        return 0
    root = tk.Tk()
    Sorter(root, targets, src)
    root.mainloop()
    left = len(collect_targets(src))
    print(f"종료: 남은 {left}장, 로그 {LOG_CSV}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
