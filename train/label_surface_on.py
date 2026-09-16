"""T94: AI Hub Surface "횡단보도 위" 사진의 각도 + 좌우 위치를 **한 번에** 매기는 도구.

대상: image_extra/on_surface_unlabeled/*.jpg (센서 방향으로 저장돼 있어 화면용으로
      시계방향 90도 되돌려 보여준다. 저장되는 좌표·각도는 **화면 방향 기준** —
      자체 사진의 label_angles.py와 같은 규약이다).

한 장의 흐름:
  1) 마우스로 "이 자리에서 건너려면 걸어갈 방향"을 드래그해 선을 긋는다
     (label_angles.py와 동일: 화면 위=0도, 시계방향=+).
  2) 키 1~5로 "지금 나는 횡단보도 폭 안에서 어디쯤인가"를 고른다
     (label_position.py와 동일: 1=왼쪽 끝, 2=왼쪽 치우침, 3=중앙, 4=오른쪽 치우침, 5=오른쪽 끝).
     → 선과 위치가 둘 다 있으면 즉시 저장하고 다음 장으로 넘어간다.
  R = 선 다시 긋기, S = 건너뛰기(횡단보도가 안 보이거나 애매), Z = 이전, Q = 종료

저장 (두 CSV, 기존 도구와 열이 같다):
  train/angle_labels_surface.csv    : class,filename,angle_deg,x1,y1,x2,y2,view_w,view_h,status
  train/position_labels_surface.csv : class,filename,position,status
  class 열은 "on_surface"로 둔다 — 방향 클래스(front/left/right)는 각도로 정한다
  (T87 규칙: |a|<15 front, >=+15 left, <=-15 right).

실행:
    python train/label_surface_on.py
"""

import csv
import math
import os
import sys
import tkinter as tk
from tkinter import messagebox

from PIL import Image, ImageTk

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(REPO, "image_extra", "on_surface_unlabeled")
ANGLE_CSV = os.path.join(REPO, "train", "angle_labels_surface.csv")
POS_CSV = os.path.join(REPO, "train", "position_labels_surface.csv")
CLASS = "on_surface"
VIEW_MAX = 820

POSITIONS = [("1", -2, "왼쪽 끝"), ("2", -1, "왼쪽 치우침"), ("3", 0, "중앙"),
             ("4", 1, "오른쪽 치우침"), ("5", 2, "오른쪽 끝")]


def collect_targets():
    return sorted(f for f in os.listdir(SRC_DIR) if f.lower().endswith((".jpg", ".png")))


def load_done():
    if not os.path.exists(ANGLE_CSV):
        return set()
    with open(ANGLE_CSV, encoding="utf-8") as f:
        return {r["filename"] for r in csv.DictReader(f)}


def ensure_csv():
    if not os.path.exists(ANGLE_CSV):
        with open(ANGLE_CSV, "w", encoding="utf-8", newline="") as f:
            csv.writer(f).writerow(["class", "filename", "angle_deg", "x1", "y1", "x2", "y2",
                                    "view_w", "view_h", "status"])
    if not os.path.exists(POS_CSV):
        with open(POS_CSV, "w", encoding="utf-8", newline="") as f:
            csv.writer(f).writerow(["class", "filename", "position", "status"])


class Labeler:
    def __init__(self, root, targets):
        self.root, self.targets, self.idx = root, targets, 0
        self.photo = None
        self.start = self.end = None
        self.position = None
        self.view_size = (0, 0)

        root.title("Surface 횡단보도 위 — 각도 + 위치 (T94)")
        self.info = tk.Label(root, font=("Malgun Gothic", 11), anchor="w", justify="left")
        self.info.pack(fill="x", padx=8, pady=(6, 0))
        tk.Label(root, text=(
            "① 드래그: 「이 자리에서 건너려면 걸어갈 방향」 (위=0도, 시계방향 +)\n"
            "② 키 1=왼쪽 끝  2=왼쪽 치우침  3=중앙  4=오른쪽 치우침  5=오른쪽 끝  → 둘 다 있으면 저장·다음\n"
            "R=선 다시   S=건너뛰기   Z=이전   Q=종료"
        ), font=("Malgun Gothic", 9), fg="#333", anchor="w", justify="left").pack(
            fill="x", padx=8, pady=(2, 4))
        self.canvas = tk.Canvas(root, bg="black", highlightthickness=0, cursor="crosshair")
        self.canvas.pack()
        self.canvas.bind("<Button-1>", self.on_press)
        self.canvas.bind("<B1-Motion>", self.on_drag)
        self.canvas.bind("<ButtonRelease-1>", self.on_release)
        for key, value, _ in POSITIONS:
            root.bind(key, lambda e, v=value: self.choose_position(v))
        for k in ("r", "R"):
            root.bind(k, lambda e: self.reset_line())
        for k in ("s", "S"):
            root.bind(k, lambda e: self.skip())
        for k in ("z", "Z"):
            root.bind(k, lambda e: self.prev())
        for k in ("q", "Q"):
            root.bind(k, lambda e: self.quit())
        self.show()

    @staticmethod
    def angle_of(p1, p2):
        dx = p2[0] - p1[0]
        dy = p2[1] - p1[1]
        return math.degrees(math.atan2(dx, -dy))

    def show(self):
        if self.idx >= len(self.targets):
            messagebox.showinfo("완료", "모든 이미지를 처리했습니다.")
            self.root.quit()
            return
        name = self.targets[self.idx]
        im = Image.open(os.path.join(SRC_DIR, name)).convert("RGB")
        im = im.rotate(-90, expand=True)  # 센서 방향 -> 화면 방향(세로)
        im.thumbnail((VIEW_MAX, VIEW_MAX))
        self.view_size = im.size
        self.photo = ImageTk.PhotoImage(im)
        self.canvas.config(width=im.size[0], height=im.size[1])
        self.start = self.end = None
        self.position = None
        self.redraw()
        self.info.config(text=f"[{self.idx + 1}/{len(self.targets)}]  {name}")

    def redraw(self):
        self.canvas.delete("all")
        self.canvas.create_image(0, 0, anchor="nw", image=self.photo)
        w, h = self.view_size
        if self.start and self.end:
            self.canvas.create_line(*self.start, *self.end, fill="#FF3B30", width=5,
                                    arrow="last", arrowshape=(18, 22, 8))
            self.canvas.create_text(12, 12, anchor="nw",
                                    text=f"{self.angle_of(self.start, self.end):+.1f}도",
                                    fill="#FFD60A", font=("Malgun Gothic", 20, "bold"))
        # 위치 눈금
        y = h - 40
        n = len(POSITIONS)
        for i, (key, value, text) in enumerate(POSITIONS):
            cx = w * (i + 0.5) / n
            chosen = self.position == value
            self.canvas.create_rectangle(cx - w / (n * 2) + 3, y - 16, cx + w / (n * 2) - 3, y + 16,
                                         fill="#FFD60A" if chosen else "#000000",
                                         outline="#FFD60A", width=2)
            self.canvas.create_text(cx, y, text=f"{key} {text}",
                                    fill="#000000" if chosen else "#FFD60A",
                                    font=("Malgun Gothic", 10, "bold"))
        status = []
        status.append("선 ✓" if (self.start and self.end) else "선 ✗")
        status.append("위치 ✓" if self.position is not None else "위치 ✗")
        self.canvas.create_text(w - 12, 12, anchor="ne", text="  ".join(status),
                                fill="#FFD60A", font=("Malgun Gothic", 12, "bold"))

    def on_press(self, e):
        self.start = (e.x, e.y); self.end = None

    def on_drag(self, e):
        if self.start:
            self.end = (e.x, e.y); self.redraw()

    def on_release(self, e):
        if self.start:
            self.end = (e.x, e.y); self.redraw(); self.try_save()

    def reset_line(self):
        self.start = self.end = None; self.redraw()

    def choose_position(self, value):
        self.position = value; self.redraw(); self.try_save()

    def try_save(self):
        if not (self.start and self.end) or self.position is None:
            return
        if self.start == self.end:
            return
        name = self.targets[self.idx]
        angle = self.angle_of(self.start, self.end)
        with open(ANGLE_CSV, "a", encoding="utf-8", newline="") as f:
            csv.writer(f).writerow([CLASS, name, f"{angle:.2f}", self.start[0], self.start[1],
                                    self.end[0], self.end[1], self.view_size[0], self.view_size[1], "ok"])
        with open(POS_CSV, "a", encoding="utf-8", newline="") as f:
            csv.writer(f).writerow([CLASS, name, self.position, "ok"])
        self.idx += 1
        self.show()

    def skip(self):
        name = self.targets[self.idx]
        with open(ANGLE_CSV, "a", encoding="utf-8", newline="") as f:
            csv.writer(f).writerow([CLASS, name, "", "", "", "", "", self.view_size[0], self.view_size[1], "skipped"])
        with open(POS_CSV, "a", encoding="utf-8", newline="") as f:
            csv.writer(f).writerow([CLASS, name, "", "skipped"])
        self.idx += 1
        self.show()

    def prev(self):
        if self.idx == 0:
            return
        self.idx -= 1
        for p in (ANGLE_CSV, POS_CSV):
            with open(p, "r", encoding="utf-8", newline="") as f:
                lines = f.readlines()
            if len(lines) > 1:
                with open(p, "w", encoding="utf-8", newline="") as f:
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
    print(f"저장: {ANGLE_CSV}, {POS_CSV} (누적 {len(load_done())}장)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
