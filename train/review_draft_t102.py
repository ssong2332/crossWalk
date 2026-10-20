"""T102: 각도·위치 라벨 **초안 검토** 도구 — 한 장씩 확인하고 틀린 것만 고친다.

초안(`train/label_draft_t102.csv`)은 배포 모델(T100 각도·위치)의 예측값이다.
이 도구는 초안 화살표를 사진 위에 그려 보여주고, 사람이 맞으면 그대로 저장,
틀리면 `label_angles.py`와 같은 방식(드래그)으로 다시 긋는다.

각도 규칙은 `label_angles.py`와 같다: 화면 위쪽이 0도, 시계방향 +.
위치 규칙은 `label_position.py`와 같다: 1~5 = -2(왼쪽 끝) ~ +2(오른쪽 끝).

키:
  Enter/Space = 지금 보이는 화살표·위치·클래스로 저장 후 다음
  드래그      = 화살표 다시 긋기 (R = 초안 화살표로 되돌리기)
  1~5         = 위치 -2 / -1 / 0 / +1 / +2
  C           = 클래스 바꾸기(approach → front → left → right 순환; 파일은 옮기지 않고 기록만)
  S           = 건너뛰기(학습에서 제외)
  Z           = 이전 장으로(기록 1줄 취소)
  Q           = 종료(다시 실행하면 이어서)

결과: `train/review_t102/review_log.csv`. 병합(angle/position_labels.csv 반영,
클래스 이동)은 검토가 끝난 뒤 별도로 한다.

실행:
    python train/review_draft_t102.py            # 75장 전체
    python train/review_draft_t102.py --flagged  # 검토 필요(🚩) 15장만
    python train/review_draft_t102.py --recheck  # 검토 후에도 15° 클래스 규칙에 걸리는 장 재확인
    python train/review_draft_t102.py --front    # 2_front 중 라벨 각도 |a|>=5 재확인(15도 기준 재검토용)

--recheck: 첫 검토 결과(review_log.csv)를 출발값으로 보여주고, 결과는
`train/review_t102/recheck_log.csv`에 따로 쓴다(첫 검토 기록은 그대로 둔다).
규칙(T100과 같다): 3_left는 각도 >= +15, 4_right는 <= -15, 2_front는 |각도| < 15.
"""

import csv
import math
import os
import sys
import tkinter as tk
from tkinter import messagebox

from PIL import Image, ImageOps, ImageTk

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMAGE_ROOT = os.path.join(REPO, "image")
DRAFT_CSV = os.path.join(REPO, "train", "label_draft_t102.csv")
OUT_CSV = os.path.join(REPO, "train", "review_t102", "review_log.csv")
CLASSES = ["1_approach", "2_front", "3_left", "4_right"]
VIEW_MAX = 820
FIELDS = ["idx", "class", "orig_class", "filename", "angle_deg", "position",
          "draft_angle", "draft_position", "angle_changed", "position_changed",
          "status"]


def load_draft(flagged_only):
    with open(DRAFT_CSV, encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))
    return [r for r in rows if r["flag"]] if flagged_only else rows


def load_done():
    if not os.path.exists(OUT_CSV):
        return set()
    with open(OUT_CSV, encoding="utf-8", newline="") as f:
        return {r["idx"] for r in csv.DictReader(f)}


def ensure_csv():
    os.makedirs(os.path.dirname(OUT_CSV), exist_ok=True)
    if not os.path.exists(OUT_CSV):
        with open(OUT_CSV, "w", encoding="utf-8", newline="") as f:
            csv.writer(f).writerow(FIELDS)


def angle_of(p1, p2):
    """label_angles.py와 같다: 위쪽 0도, 시계방향 +."""
    return math.degrees(math.atan2(p2[0] - p1[0], -(p2[1] - p1[1])))


class Reviewer:
    def __init__(self, root, rows):
        self.root, self.rows, self.i = root, rows, 0
        self.photo = None
        root.title("T102 라벨 초안 검토 — 맞으면 Enter, 틀리면 드래그로 다시 긋기")
        self.info = tk.Label(root, font=("Malgun Gothic", 11), anchor="w",
                             justify="left")
        self.info.pack(fill="x", padx=8, pady=(6, 0))
        self.flag = tk.Label(root, font=("Malgun Gothic", 11, "bold"),
                             fg="#D70015", anchor="w", justify="left",
                             wraplength=VIEW_MAX)
        self.flag.pack(fill="x", padx=8)
        tk.Label(root, font=("Malgun Gothic", 9), fg="#333", anchor="w",
                 justify="left",
                 text="파란 점선 = 모델 초안   빨간 화살표 = 저장될 값   "
                      "Enter/Space 저장·다음   드래그 다시 긋기   R 초안으로   "
                      "1~5 위치(-2~+2)   C 클래스   S 건너뛰기   Z 이전   Q 종료"
                 ).pack(fill="x", padx=8, pady=(2, 4))
        self.canvas = tk.Canvas(root, bg="black", highlightthickness=0)
        self.canvas.pack()
        self.canvas.bind("<Button-1>", self.on_press)
        self.canvas.bind("<B1-Motion>", self.on_drag)
        self.canvas.bind("<ButtonRelease-1>", self.on_drag)
        for k, fn in [("<Return>", self.save), ("<space>", self.save),
                      ("s", self.skip), ("S", self.skip), ("z", self.prev),
                      ("Z", self.prev), ("r", self.reset), ("R", self.reset),
                      ("c", self.cycle_class), ("C", self.cycle_class),
                      ("q", self.quit), ("Q", self.quit)]:
            root.bind(k, lambda e, f=fn: f())
        for n in range(1, 6):
            root.bind(str(n), lambda e, v=n - 3: self.set_pos(v))
        self.show()

    # ---- 표시 ---------------------------------------------------------
    def draft_line(self):
        """초안 각도를 화면 아래 중앙에서 뻗는 화살표로 만든다."""
        w, h = self.view
        x0, y0, length = w / 2, h * 0.92, h * 0.45
        a = math.radians(float(self.row["angle_deg"]))
        return (x0, y0), (x0 + length * math.sin(a), y0 - length * math.cos(a))

    def show(self):
        if self.i >= len(self.rows):
            messagebox.showinfo("완료", "검토를 모두 마쳤습니다.")
            self.root.quit()
            return
        self.row = self.rows[self.i]
        path = os.path.join(IMAGE_ROOT, self.row["class"], self.row["filename"])
        im = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
        im.thumbnail((VIEW_MAX, VIEW_MAX))
        self.view = im.size
        self.photo = ImageTk.PhotoImage(im)
        self.canvas.config(width=im.size[0], height=im.size[1])
        self.start, self.end = self.draft_line()
        self.pos = int(self.row["position"])
        self.cls = self.row["class"]
        self.flag.config(text=("🚩 " + self.row["flag"]) if self.row["flag"] else "")
        self.redraw()

    def redraw(self):
        c = self.canvas
        c.delete("all")
        c.create_image(0, 0, anchor="nw", image=self.photo)
        w, h = self.view
        c.create_line(w / 2, 0, w / 2, h, fill="#00FFFF", dash=(3, 6))
        for fr in (1 / 3, 2 / 3):  # 위치 눈금(label_position.py와 같은 1/3·2/3)
            c.create_line(w * fr, h - 40, w * fr, h, fill="#FF00FF", width=2)
        ds, de = self.draft_line()
        c.create_line(*ds, *de, fill="#0A84FF", width=3, dash=(8, 6),
                      arrow="last")
        c.create_line(*self.start, *self.end, fill="#FF3B30", width=5,
                      arrow="last", arrowshape=(18, 22, 8))
        ang = angle_of(self.start, self.end)
        cls_txt = self.cls + ("  (클래스 변경)" if self.cls != self.row["class"] else "")
        c.create_text(12, 12, anchor="nw", fill="#FFD60A",
                      font=("Malgun Gothic", 20, "bold"),
                      text=f"각도 {ang:+.1f}도   위치 {self.pos:+d}\n{cls_txt}")
        self.info.config(text=f"[{self.i + 1}/{len(self.rows)}]  #{self.row['idx']}  "
                              f"{self.row['class']}/{self.row['filename']}   "
                              f"초안: 각도 {float(self.row['angle_deg']):+.1f}도, "
                              f"위치 {int(self.row['position']):+d}")

    # ---- 입력 ---------------------------------------------------------
    def on_press(self, e):
        self.start = self.end = (e.x, e.y)

    def on_drag(self, e):
        self.end = (e.x, e.y)
        self.redraw()

    def reset(self):
        self.start, self.end = self.draft_line()
        self.redraw()

    def set_pos(self, v):
        self.pos = v
        self.redraw()

    def cycle_class(self):
        self.cls = CLASSES[(CLASSES.index(self.cls) + 1) % len(CLASSES)]
        self.redraw()

    # ---- 저장/이동 ------------------------------------------------------
    def write(self, status, angle=None):
        r = self.row
        with open(OUT_CSV, "a", encoding="utf-8", newline="") as f:
            csv.writer(f).writerow([
                r["idx"], self.cls, r["class"], r["filename"],
                "" if angle is None else f"{angle:.2f}",
                "" if status == "skipped" else self.pos,
                r["angle_deg"], r["position"],
                "" if angle is None else int(abs(angle - float(r["angle_deg"])) > 0.5),
                int(self.pos != int(r["position"])), status])

    def save(self):
        if self.start == self.end:
            return  # 길이 0인 선은 방향이 없다
        self.write("ok", angle_of(self.start, self.end))
        self.i += 1
        self.show()

    def skip(self):
        self.write("skipped")
        self.i += 1
        self.show()

    def prev(self):
        if self.i == 0:
            return
        with open(OUT_CSV, encoding="utf-8", newline="") as f:
            lines = f.readlines()
        if len(lines) > 1:
            with open(OUT_CSV, "w", encoding="utf-8", newline="") as f:
                f.writelines(lines[:-1])
        self.i -= 1
        self.show()

    def quit(self):
        self.root.quit()


def rule_violation(cls, angle):
    """T100의 15도 규칙에 어긋나면 사유 문자열, 아니면 빈 문자열."""
    if cls == "3_left" and angle < 15:
        return "규칙: 3_left인데 각도 < +15 — 2_front로 옮길지(C) 각도를 고칠지"
    if cls == "4_right" and angle > -15:
        return "규칙: 4_right인데 각도 > -15 — 2_front로 옮길지(C) 각도를 고칠지"
    if cls == "2_front" and abs(angle) >= 15:
        return "규칙: 2_front인데 |각도| >= 15 — 좌/우로 옮길지(C) 각도를 고칠지"
    return ""


def load_recheck():
    """첫 검토 결과 중 (검토 후 클래스 기준) 규칙 위반 행을 초안 형식으로 만든다."""
    global OUT_CSV
    with open(OUT_CSV, encoding="utf-8", newline="") as f:
        reviewed = list(csv.DictReader(f))
    OUT_CSV = os.path.join(os.path.dirname(OUT_CSV), "recheck_log.csv")
    rows = []
    for r in reviewed:
        flag = rule_violation(r["class"], float(r["angle_deg"]))
        if flag:
            rows.append({"idx": r["idx"], "class": r["orig_class"],
                         "filename": r["filename"], "angle_deg": r["angle_deg"],
                         "position": r["position"], "flag": flag})
    return rows


def load_front(min_abs=5.0):
    """T102: 2_front 중 라벨 각도 |a| >= min_abs. 15도 기준을 낮출지 판단하려고
    '직진'으로 매겨진 작은 각도 사진을 다시 본다. 큰 각도부터 보여준다.
    화살표·위치는 현재 라벨(angle/position_labels.csv) 값이다."""
    global OUT_CSV
    OUT_CSV = os.path.join(os.path.dirname(OUT_CSV), "front_review_log.csv")
    base = os.path.join(REPO, "train")
    with open(os.path.join(base, "position_labels.csv"), encoding="utf-8") as f:
        pos = {r["filename"]: r["position"] for r in csv.DictReader(f)
               if r["class"] == "2_front" and r["status"] == "ok"}
    with open(os.path.join(base, "class_move_t100.csv"), encoding="utf-8") as f:
        moved = {r["filename"]: r["from"] for r in csv.DictReader(f)}
    with open(os.path.join(base, "angle_labels.csv"), encoding="utf-8") as f:
        rows = [r for r in csv.DictReader(f) if r["class"] == "2_front"
                and r["status"] == "ok" and abs(float(r["angle_deg"])) >= min_abs]
    rows.sort(key=lambda r: -abs(float(r["angle_deg"])))
    out = []
    for i, r in enumerate(rows):
        notes = [f"라벨 각도 {float(r['angle_deg']):+.1f}도 — 직진이 맞으면 Enter, 이탈이면 C로 클래스 변경"]
        if r["filename"] in moved:
            notes.append(f"T100에서 {moved[r['filename']]} -> 2_front로 옮긴 사진")
        if r["filename"] not in pos:
            notes.append("위치 라벨 없음(0으로 표시)")
        out.append({"idx": f"f{i}", "class": "2_front", "filename": r["filename"],
                    "angle_deg": r["angle_deg"], "position": pos.get(r["filename"], "0"),
                    "flag": " / ".join(notes)})
    return out


def main():
    flagged = "--flagged" in sys.argv
    if "--recheck" in sys.argv or "--front" in sys.argv:
        rows = load_recheck() if "--recheck" in sys.argv else load_front()
        ensure_csv()
        done = load_done()
        rows = [r for r in rows if r["idx"] not in done]
        print(f"대상 남은 {len(rows)}장 (완료 {len(done)}장, 기록: {OUT_CSV})")
        if rows:
            root = tk.Tk()
            Reviewer(root, rows)
            root.mainloop()
        return 0
    ensure_csv()
    done = load_done()
    rows = [r for r in load_draft(flagged) if r["idx"] not in done]
    print(f"검토 대상 {'(🚩만) ' if flagged else ''}남은 {len(rows)}장 "
          f"(완료 {len(done)}장, 기록: {OUT_CSV})")
    if not rows:
        return 0
    root = tk.Tk()
    Reviewer(root, rows)
    root.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
