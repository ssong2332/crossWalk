"""T74: 횡단보도 내 **좌우 위치** 라벨링 도구.

배경 — 왜 이 도구가 필요한가 (2026-09-04, 사용자 진술):
  사용자가 각도를 매길 때 "같은 이탈 각도라도 중앙에서 벗어나는 것보다
  측면에서 벗어나는 것이 더 위험하니 일부러 각도를 더 줬다"고 밝혔다.
  즉 `angle_labels.csv`의 각도는 **순수 기하값이 아니라 위험 가중이 섞인
  제어 신호**다. 이 때문에 세 가지 문제가 생겼다:
    (1) 각도를 사진과 대조해 검증할 수 없다 — 안 맞는 게 정상이 된다.
    (2) 화면의 "각도 -10도" 표시가 실제 방향이 아니게 되어 사용자를 오도한다.
    (3) 방향과 위치라는 두 신호가 스칼라 하나에 섞여 학습 난이도가 오른다.

  또한 "횡단보도를 감지하니 위치도 알 수 있지 않냐"는 가정은 성립하지 않는다.
  실제 모델 출력은 분류기 [1,5](클래스 확률)와 각도 [1,1](스칼라)뿐이고,
  횡단보도의 위치나 영역을 내는 출력이 **없다**(배포 ONNX에서 직접 확인).

  그래서 위치를 별도 라벨로 분리한다(사용자 선택: B안, 2026-09-04).
  분리하면 (a) 각도는 다시 검증 가능한 기하값이 되고, (b) 위험 가중을
  앱에서 **명시적 규칙**으로 적용해 세기를 조절할 수 있다.

라벨링 규칙 (이 규칙 하나로만 매긴다):
  **"지금 나는 횡단보도의 폭 안에서 어디쯤 서 있는가"** 를 고른다.
  - 진행 방향이 아니라 **좌우 위치**다. 어느 쪽으로 걷고 있는지는 무관하다.
  - 1_approach는 아직 올라서기 전이므로 "앞에 보이는 횡단보도의 폭 기준으로
    내가 어느 쪽에 서 있는가"로 판단한다.
  - 부호는 각도와 같은 관례를 쓴다: **왼쪽이 음수, 오른쪽이 양수.**

    키   값    의미
     1   -2    왼쪽 끝 (한 발만 더 가면 횡단보도 밖)
     2   -1    왼쪽으로 치우침
     3    0    중앙
     4   +1    오른쪽으로 치우침
     5   +2    오른쪽 끝

건너뛰기(S): 횡단보도 폭을 가늠할 수 없으면 건너뛴다.
  억지로 매긴 라벨은 학습을 망치므로 애매하면 건너뛰는 편이 낫다.
  (T73 시점 교훈: 데이터를 줄일 목적으로 건너뛰면 안 된다 — 과적합은
  누수 없는 교차검증으로 거르지, 라벨을 빼서 막는 것이 아니다.)

저장: train/position_labels.csv 에 한 줄씩 즉시 append 된다(중간에 꺼도 안전).
  다시 실행하면 이미 라벨링한 파일은 자동으로 건너뛰고 이어서 진행한다.

실행:
    python train/label_position.py
"""

import csv
import os
import tkinter as tk
from tkinter import messagebox

from PIL import Image, ImageOps, ImageTk

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMAGE_ROOT = os.path.join(REPO, "image")
OUT_CSV = os.path.join(REPO, "train", "position_labels.csv")

# 각도 라벨링과 같은 대상. 0_none은 횡단보도가 없으므로 제외한다.
LABEL_CLASSES = ["1_approach", "2_front", "3_left", "4_right"]

VIEW_MAX = 820  # 화면에 띄울 최대 변 길이(px)

# 키 -> (값, 표시 문구). 값의 부호는 각도 라벨과 같은 관례(왼쪽 -, 오른쪽 +).
CHOICES = [
    ("1", -2, "왼쪽 끝"),
    ("2", -1, "왼쪽 치우침"),
    ("3", 0, "중앙"),
    ("4", +1, "오른쪽 치우침"),
    ("5", +2, "오른쪽 끝"),
]


def collect_targets():
    targets = []
    for cls in LABEL_CLASSES:
        d = os.path.join(IMAGE_ROOT, cls)
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if name.lower().endswith((".jpg", ".jpeg", ".png")):
                targets.append((cls, name, os.path.join(d, name)))
    return targets


def load_done():
    """이미 라벨링된 (cls, name) 집합. 중간에 꺼도 이어서 할 수 있게 한다."""
    done = set()
    if os.path.exists(OUT_CSV):
        with open(OUT_CSV, "r", encoding="utf-8", newline="") as f:
            for row in csv.DictReader(f):
                done.add((row["class"], row["filename"]))
    return done


def ensure_csv():
    if not os.path.exists(OUT_CSV):
        with open(OUT_CSV, "w", encoding="utf-8", newline="") as f:
            csv.writer(f).writerow(["class", "filename", "position", "status"])


class Labeler:
    def __init__(self, root, targets):
        self.root = root
        self.targets = targets
        self.idx = 0
        self.photo = None

        root.title("횡단보도 내 좌우 위치 라벨링 (T74)")

        self.info = tk.Label(root, font=("Malgun Gothic", 11), anchor="w",
                             justify="left")
        self.info.pack(fill="x", padx=8, pady=(6, 0))

        help_text = (
            "규칙: 「지금 나는 횡단보도 폭 안에서 어디쯤인가」를 고르세요 "
            "(진행 방향 아님).\n"
            "1=왼쪽 끝   2=왼쪽 치우침   3=중앙   4=오른쪽 치우침   "
            "5=오른쪽 끝\n"
            "S=건너뛰기   Z=이전으로   Q=종료"
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

    # ---- 표시 -----------------------------------------------------------
    def show(self):
        if self.idx >= len(self.targets):
            messagebox.showinfo("완료", "모든 이미지를 처리했습니다.")
            self.root.quit()
            return

        cls, name, path = self.targets[self.idx]
        im = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
        im.thumbnail((VIEW_MAX, VIEW_MAX))
        self.photo = ImageTk.PhotoImage(im)

        self.canvas.config(width=im.size[0], height=im.size[1])
        self.canvas.delete("all")
        self.canvas.create_image(0, 0, anchor="nw", image=self.photo)
        self._draw_scale(im.size[0], im.size[1])

        self.info.config(
            text=f"[{self.idx + 1}/{len(self.targets)}]  {cls}/{name}"
        )

    def _draw_scale(self, w, h):
        """화면 아래에 5단계 눈금을 그려 어떤 키가 어느 쪽인지 헷갈리지 않게 한다."""
        y = h - 40
        n = len(CHOICES)
        for i, (key, _, text) in enumerate(CHOICES):
            cx = w * (i + 0.5) / n
            self.canvas.create_rectangle(
                cx - w / (n * 2) + 4, y - 16, cx + w / (n * 2) - 4, y + 16,
                fill="#000000", outline="#FFD60A", width=2)
            self.canvas.create_text(
                cx, y, text=f"{key}  {text}",
                fill="#FFD60A", font=("Malgun Gothic", 11, "bold"))

    # ---- 저장/이동 -------------------------------------------------------
    def write_row(self, status, position=None):
        cls, name, _ = self.targets[self.idx]
        with open(OUT_CSV, "a", encoding="utf-8", newline="") as f:
            csv.writer(f).writerow([
                cls, name,
                "" if position is None else position,
                status,
            ])

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
        """직전 이미지로 되돌아간다. CSV의 마지막 줄을 지워 다시 매길 수 있게 한다."""
        if self.idx == 0:
            return
        self.idx -= 1
        self._drop_last_csv_row()
        self.show()

    @staticmethod
    def _drop_last_csv_row():
        with open(OUT_CSV, "r", encoding="utf-8", newline="") as f:
            lines = f.readlines()
        if len(lines) > 1:  # 헤더는 남긴다
            with open(OUT_CSV, "w", encoding="utf-8", newline="") as f:
                f.writelines(lines[:-1])

    def quit(self):
        self.root.quit()


def main():
    if not os.path.isdir(IMAGE_ROOT):
        print(f"이미지 폴더를 찾을 수 없습니다: {IMAGE_ROOT}")
        return 1

    ensure_csv()
    done = load_done()
    all_targets = collect_targets()
    targets = [t for t in all_targets if (t[0], t[1]) not in done]

    print(f"라벨링 대상 총 {len(all_targets)}장 중 "
          f"이미 완료 {len(done)}장 -> 남은 {len(targets)}장")
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
    raise SystemExit(main())
