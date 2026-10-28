"""T150: 10/25~28 실기기 프레임 각도 라벨링 도구 (시범 50장, 본 목록 413장).

긋는 규칙 (사용자 확인, 2026-10-28): 줄무늬 방향으로 긋는다(기존 라벨과 같은 기준).
비스듬한 횡단보도는 S(건너뛰기).

`label_angles.py`(T81)·`label_surface_on.py`(T94)와 같은 규약이다:
  - 선을 드래그해 긋는다. 화면 위쪽=0도, 시계방향=+, 반시계방향=−.
  - 프레임은 센서 방향(가로 720×480)으로 저장돼 있어 시계방향 90도 돌려 보여 준다.
    저장하는 좌표·각도는 **화면 방향 기준**이다 (T94와 같음).
  - 위험하다고 각도를 더 꺾지 않는다 (위험 가중은 `apply_risk_weighting.py`가 따로).
  - 모델 예측 각도는 보여 주지 않는다 (라벨이 예측에 끌려가지 않게).

저장 (즉시 append, 중간에 꺼도 안전, 다시 실행하면 이어서):
  --out  (기본 train/angle_labels_t150_pilot.csv)
         class,filename,angle_deg,x1,y1,x2,y2,view_w,view_h,status  ← angle_labels.csv와 같은 열
         class 열 = 프레임 폴더 이름(예: frames_1027). 파일 위치 = <root>/train/<class>/<filename>
  --out 이름 + _times.csv  (장당 소요 시간, 라벨 파일과 분리)
         class,filename,action,sec,at
         action = ok / skipped / undo. 되돌린 장의 시간도 지우지 않는다(실제 쓴 시간 합계용).

키: 드래그=선  Enter/Space=저장 후 다음  S=건너뛰기  Z=이전 장으로(그 장 라벨 지움)
    R=선 다시 긋기  Q=종료

실행 (저장소 루트에서):
    python train/t150_label_angles.py --root C:/vibecoding/crossWalk                 (시범 50장)
    python train/t150_label_angles.py --root C:/vibecoding/crossWalk         --list train/t150_main413.csv --out train/angle_labels_t150_main.csv         (본 413장)
시간 요약만 보기:
    python train/t150_label_angles.py --summary
"""

import argparse
import csv
import math
import os
import statistics
import sys
import time
import tkinter as tk
from datetime import datetime
from tkinter import messagebox

from PIL import Image, ImageTk

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
VIEW_MAX = 820
LABEL_COLS = ["class", "filename", "angle_deg", "x1", "y1", "x2", "y2",
              "view_w", "view_h", "status"]
TIME_COLS = ["class", "filename", "action", "sec", "at"]


def times_path(out):
    return os.path.splitext(out)[0] + "_times.csv"


def ensure(path, cols):
    if not os.path.exists(path):
        with open(path, "w", encoding="utf-8", newline="") as f:
            csv.writer(f).writerow(cols)


def load_targets(list_csv, root):
    with open(list_csv, encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    return [(r["folder"], r["filename"],
             os.path.join(root, "train", r["folder"], r["filename"])) for r in rows]


def load_done(out):
    if not os.path.exists(out):
        return set()
    with open(out, encoding="utf-8", newline="") as f:
        return {(r["class"], r["filename"]) for r in csv.DictReader(f)}


def drop_row(path, key):
    """key=(class, filename)인 줄을 지운다 (마지막 줄이라고 가정하지 않는다)."""
    with open(path, encoding="utf-8", newline="") as f:
        rows = list(csv.reader(f))
    keep = [rows[0]] + [r for r in rows[1:] if (r[0], r[1]) != key]
    with open(path, "w", encoding="utf-8", newline="") as f:
        csv.writer(f).writerows(keep)


class Labeler:
    def __init__(self, root, targets, out):
        self.root = root
        self.targets = targets
        self.out = out
        self.tout = times_path(out)
        self.idx = 0
        self.start = self.end = None
        self.photo = None
        self.view_size = (0, 0)
        self.t0 = time.monotonic()

        root.title("T150 각도 라벨링 — 10/25~28 프레임")
        self.info = tk.Label(root, font=("Malgun Gothic", 11), anchor="w", justify="left")
        self.info.pack(fill="x", padx=8, pady=(6, 0))
        help_text = (
            "규칙: 줄무늬 방향으로 드래그해서 긋기 (기존 라벨과 같은 기준). "
            "비스듬한 횡단보도·애매하면 S. 위험하다고 더 꺾지 않기.\n"
            "드래그=선   Enter/Space=저장 후 다음   S=건너뛰기(안 보이거나 애매)   "
            "Z=이전 장   R=다시 긋기   Q=종료(다음에 이어서)"
        )
        tk.Label(root, text=help_text, font=("Malgun Gothic", 9), fg="#333",
                 anchor="w", justify="left").pack(fill="x", padx=8, pady=(2, 4))
        self.canvas = tk.Canvas(root, bg="black", highlightthickness=0)
        self.canvas.pack()

        self.canvas.bind("<Button-1>", self.on_press)
        self.canvas.bind("<B1-Motion>", self.on_drag)
        self.canvas.bind("<ButtonRelease-1>", self.on_drag)
        for keys, fn in ((("<Return>", "<space>"), self.save_and_next),
                         (("s", "S"), self.skip), (("z", "Z"), self.prev),
                         (("r", "R"), self.reset_line), (("q", "Q"), self.root.quit)):
            for k in keys:
                root.bind(k, lambda e, fn=fn: fn())
        self.show()

    @staticmethod
    def angle_of(p1, p2):
        """화면 위쪽 0도, 시계방향 + (label_angles.py와 같은 식)."""
        return math.degrees(math.atan2(p2[0] - p1[0], -(p2[1] - p1[1])))

    def show(self):
        if self.idx >= len(self.targets):
            messagebox.showinfo("완료", "목록의 사진을 모두 처리했습니다.")
            self.root.quit()
            return
        cls, name, path = self.targets[self.idx]
        im = Image.open(path).convert("RGB")
        im = im.rotate(-90, expand=True)  # 센서 방향 -> 화면 방향(세로), T94와 같음
        im.thumbnail((VIEW_MAX, VIEW_MAX))
        self.view_size = im.size
        self.photo = ImageTk.PhotoImage(im)
        self.canvas.config(width=im.size[0], height=im.size[1])
        self.redraw()
        self.info.config(text=f"[{self.idx + 1}/{len(self.targets)}]  {cls}/{name}")
        self.t0 = time.monotonic()

    def redraw(self):
        self.canvas.delete("all")
        self.canvas.create_image(0, 0, anchor="nw", image=self.photo)
        if self.start and self.end:
            self.canvas.create_line(*self.start, *self.end, fill="#FF3B30", width=5,
                                    arrow="last", arrowshape=(18, 22, 8))
            self.canvas.create_text(12, 12, anchor="nw",
                                    text=f"{self.angle_of(self.start, self.end):+.1f}도",
                                    fill="#FFD60A", font=("Malgun Gothic", 20, "bold"))

    def on_press(self, e):
        self.start, self.end = (e.x, e.y), None

    def on_drag(self, e):
        if self.start:
            self.end = (e.x, e.y)
            self.redraw()

    def reset_line(self):
        self.start = self.end = None
        self.redraw()

    def log_time(self, cls, name, action):
        with open(self.tout, "a", encoding="utf-8", newline="") as f:
            csv.writer(f).writerow([cls, name, action, f"{time.monotonic() - self.t0:.1f}",
                                    datetime.now().isoformat(timespec="seconds")])

    def write_row(self, status, angle=None):
        cls, name, _ = self.targets[self.idx]
        with open(self.out, "a", encoding="utf-8", newline="") as f:
            csv.writer(f).writerow([
                cls, name, "" if angle is None else f"{angle:.2f}",
                "" if not self.start else self.start[0],
                "" if not self.start else self.start[1],
                "" if not self.end else self.end[0],
                "" if not self.end else self.end[1],
                self.view_size[0], self.view_size[1], status,
            ])
        self.log_time(cls, name, status)

    def save_and_next(self):
        if not (self.start and self.end) or self.start == self.end:
            return  # 선이 없거나 길이 0이면 저장하지 않는다
        self.write_row("ok", self.angle_of(self.start, self.end))
        self.advance()

    def skip(self):
        self.write_row("skipped")
        self.advance()

    def advance(self):
        self.idx += 1
        self.start = self.end = None
        self.show()

    def prev(self):
        """이번 실행에서 처리한 직전 장으로 돌아가고 그 장의 라벨 줄을 지운다."""
        if self.idx == 0:
            return
        cls, name, _ = self.targets[self.idx]
        self.log_time(cls, name, "undo")  # 지금 장에서 쓴 시간도 남긴다
        self.idx -= 1
        drop_row(self.out, self.targets[self.idx][:2])
        self.start = self.end = None
        self.show()


def summary(out, n_list=0):
    tp = times_path(out)
    if not os.path.exists(tp):
        print(f"시간 기록 없음: {tp}")
        return 0
    with open(tp, encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    secs = [float(r["sec"]) for r in rows]
    done = [float(r["sec"]) for r in rows if r["action"] in ("ok", "skipped")]
    labels = load_done(out)
    with open(out, encoding="utf-8") as f:
        st = [r["status"] for r in csv.DictReader(f)]
    print(f"라벨 파일: {out}  ok {st.count('ok')} / skipped {st.count('skipped')} (총 {len(labels)}장)")
    print(f"쓴 시간 합계(되돌린 것 포함): {sum(secs):.0f}초 = {sum(secs) / 60:.1f}분")
    if done:
        print(f"장당(ok·skipped 기록 {len(done)}개): 중앙값 {statistics.median(done):.1f}초, "
              f"평균 {statistics.mean(done):.1f}초, 최대 {max(done):.1f}초")
        per = sum(secs) / len(labels) if labels else 0
        print(f"전체 시간 ÷ 장수 = {per:.1f}초/장")
        if n_list:
            left = n_list - len(labels)
            print(f"목록 {n_list}장 중 남은 {left}장 → 같은 속도면 약 {per * left / 60:.0f}분")
    return 0


def main():
    # 이 PC 콘솔(cp1252)에서 한글 print가 죽는 일이 있어(CLAUDE.md T106 행) 미리 막는다
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=REPO, help="train/frames_* 가 있는 저장소 루트")
    ap.add_argument("--list", default=os.path.join(HERE, "t150_pilot50.csv"))
    ap.add_argument("--out", default=os.path.join(HERE, "angle_labels_t150_pilot.csv"))
    ap.add_argument("--summary", action="store_true", help="시간 요약만 출력")
    a = ap.parse_args()
    n_list = len(load_targets(a.list, a.root)) if os.path.exists(a.list) else 0
    if a.summary:
        return summary(a.out, n_list)

    all_targets = load_targets(a.list, a.root)
    missing = [p for _, _, p in all_targets if not os.path.exists(p)]
    if missing:
        print(f"사진 {len(missing)}장을 찾을 수 없습니다 (예: {missing[0]}). --root 를 확인하세요.")
        return 1
    ensure(a.out, LABEL_COLS)
    ensure(times_path(a.out), TIME_COLS)
    done = load_done(a.out)
    targets = [t for t in all_targets if (t[0], t[1]) not in done]
    print(f"대상 {len(all_targets)}장 중 완료 {len(all_targets) - len(targets)}장 -> 남은 {len(targets)}장")
    if not targets:
        return summary(a.out, n_list)

    root = tk.Tk()
    Labeler(root, targets, a.out)
    root.mainloop()
    return summary(a.out, n_list)


if __name__ == "__main__":
    sys.exit(main())
