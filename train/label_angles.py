"""T68/T81: 횡단보도 진행 방향 각도 라벨링 도구 — v3(순수 기하), 전체 재라벨.

배경 — 왜 이 도구가 필요한가:
  고전 CV(T66~T67, `StripeDirectionEstimator`)로 줄무늬 각도를 추정해 화살표를
  돌려봤으나 실제 사진에서 실패했다(실측: 같은 사진이 축소 크기만 바뀌어도
  -1.8~11.1도로 12.9도 흔들림, 신뢰도 중앙값 26%, 화살표 게이트 통과 58%).
  원인은 원근 — 가까운 줄무늬와 먼 줄무늬의 각도가 서로 달라 "하나의 대표
  각도"가 애초에 잘 정의되지 않는다. 파라미터 튜닝으로 풀 문제가 아니라서
  사용자가 A안(각도 정답을 매겨 모델 학습)을 선택했다(2026-08-29).

T81(2026-09-08) — v2에서 v3로 전면 재라벨하는 이유:
  v1/v2 라벨(`train/angle_labels_v2_604_final.csv`에 보존)은 사람이 위험도를
  보며 손으로 각도를 키워 매긴 값이 섞여 있었다(T74에서 확인: 위치 한 단계당
  +7.3도, front는 무관). 이게 (a) 각도를 사진과 대조해 검증할 수 없고,
  (b) 화면 표시가 실제 방향이 아니게 되어 사용자를 오도하고, (c) 라벨링할
  때마다 위험도를 얼마나 반영할지 기준이 없어 일관성이 흔들리는 문제를
  낳았다(v1→v2 재라벨 사유 자체가 그 일관성 문제였다).

  그래서 이번 v3부터 **역할을 분리한다**:
    - 사람(이 도구) = **순수 기하 각도만** 매긴다. 위험하다고 각도를 키우거나
      줄이지 않는다 — 오직 "사진에 보이는 대로 이 자리에서 걸어갈 방향"만.
    - 시스템(`train/apply_risk_weighting.py`, 이후 작성) = 별도로 매긴
      위치 라벨(`train/label_position.py`)을 이용해 위험 가중을 **투명하고
      재현 가능한 공식**으로 나중에 얹는다. 기하값과 가중값이 분리되어 있으면
      가중 공식만 바꿔서 재실험할 수 있고, 화면에 "보정"이 아니라 "각도"라고
      다시 표시할 수도 있다.

라벨링 규칙 (이 규칙 하나로만 매긴다):
  **"지금 이 자리에서 횡단보도를 건너려면 걸어갈 방향"** 을 선으로 긋는다.
  - 줄무늬 각도가 아니라 **진행 방향**이다. 줄무늬는 원근으로 화면 위치마다
    각도가 달라 애매하지만, 진행 방향은 사람이 보면 하나로 정해진다.
  - **카메라(사진) 기준이다.** 사진에 보이는 원근을 그대로 두고, "사람 눈으로
    보면 이렇게 안 보일 것 같다"는 식으로 보정하지 않는다 — 모델이 실제로
    보는 입력은 사진뿐이고, 화살표 렌더링(`GroundProjection`)도 사진 기준
    화면각을 카메라 가정값(화각 51도·높이 1.30m·pitch 12도)으로 지면에
    되돌리는 계산이라, 라벨이 사진 기준이 아니면 이 계산 전체가 어긋난다.
  - **위험하다고 각도를 더 꺾지 않는다.** 왼쪽 가장자리에 서 있어도, 실제로
    걸어야 할 방향이 15도면 15도로만 긋는다. 더 위험해 보이게 하려고
    20도, 25도로 부풀리지 않는다 — 그건 이 도구가 아니라 위치 라벨을 보고
    시스템이 나중에 일괄 적용한다.
  - 화면 위쪽(정면)이 0도. 시계방향이 +, 반시계방향이 −.

건너뛰기(S): 횡단보도가 안 보이거나 방향을 정할 수 없으면 건너뛴다.
  억지로 매긴 라벨은 학습을 망치므로 애매하면 건너뛰는 편이 낫다.

저장: train/angle_labels.csv 에 한 줄씩 즉시 append 된다(중간에 꺼도 안전).
  다시 실행하면 이미 라벨링한 파일은 자동으로 건너뛰고 이어서 진행한다.
  이 파일은 T81에서 전면 재라벨을 위해 **비워졌다** — 이전 v2(604장) 값은
  `train/angle_labels_v2_604_final.csv`에 그대로 남아 있다.

실행:
    python train/label_angles.py
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
OUT_CSV = os.path.join(REPO, "train", "angle_labels.csv")

# 횡단보도가 보이는 클래스만 라벨링한다. 0_none은 횡단보도가 없으므로 제외.
LABEL_CLASSES = ["1_approach", "2_front", "3_left", "4_right"]

VIEW_MAX = 820  # 화면에 띄울 최대 변 길이(px)


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
            csv.writer(f).writerow(
                ["class", "filename", "angle_deg", "x1", "y1", "x2", "y2",
                 "view_w", "view_h", "status"]
            )


class Labeler:
    def __init__(self, root, targets):
        self.root = root
        self.targets = targets
        self.idx = 0
        self.start = None
        self.end = None
        self.photo = None
        self.view_size = (0, 0)

        root.title("횡단보도 진행 방향 라벨링 v3 — 순수 기하 (T81)")

        self.info = tk.Label(root, font=("Malgun Gothic", 11), anchor="w",
                             justify="left")
        self.info.pack(fill="x", padx=8, pady=(6, 0))

        help_text = (
            "규칙: 「이 자리에서 건너려면 걸어갈 방향」을 사진에 보이는 대로만 "
            "드래그해서 그으세요 (줄무늬 방향 아님).\n"
            "⚠ 위험하다고 각도를 더 꺾지 마세요 — 위험 가중은 시스템이 위치 "
            "라벨로 나중에 따로 더합니다. 이 도구는 순수 기하 각도만.\n"
            "드래그=선 긋기   Enter/Space=저장 후 다음   S=건너뛰기   "
            "Z=이전으로   R=다시 긋기   Q=종료"
        )
        tk.Label(root, text=help_text, font=("Malgun Gothic", 9),
                 fg="#333", anchor="w", justify="left").pack(
            fill="x", padx=8, pady=(2, 4))

        self.canvas = tk.Canvas(root, bg="black", highlightthickness=0)
        self.canvas.pack()

        self.canvas.bind("<Button-1>", self.on_press)
        self.canvas.bind("<B1-Motion>", self.on_drag)
        self.canvas.bind("<ButtonRelease-1>", self.on_release)

        root.bind("<Return>", lambda e: self.save_and_next())
        root.bind("<space>", lambda e: self.save_and_next())
        root.bind("s", lambda e: self.skip())
        root.bind("S", lambda e: self.skip())
        root.bind("z", lambda e: self.prev())
        root.bind("Z", lambda e: self.prev())
        root.bind("r", lambda e: self.reset_line())
        root.bind("R", lambda e: self.reset_line())
        root.bind("q", lambda e: self.quit())
        root.bind("Q", lambda e: self.quit())

        self.show()

    # ---- 각도 계산 -------------------------------------------------------
    @staticmethod
    def angle_of(p1, p2):
        """화면 위쪽을 0도로, 시계방향을 +로 하는 진행 방향 각도.

        캔버스 좌표는 y가 아래로 증가하므로, 위쪽 방향은 (0, -1)이다.
        atan2(dx, -dy)를 쓰면 위쪽이 0, 오른쪽이 +90이 된다.
        """
        dx = p2[0] - p1[0]
        dy = p2[1] - p1[1]
        return math.degrees(math.atan2(dx, -dy))

    # ---- 표시 -----------------------------------------------------------
    def show(self):
        if self.idx >= len(self.targets):
            messagebox.showinfo("완료", "모든 이미지를 처리했습니다.")
            self.root.quit()
            return

        cls, name, path = self.targets[self.idx]
        im = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
        im.thumbnail((VIEW_MAX, VIEW_MAX))
        self.view_size = im.size
        self.photo = ImageTk.PhotoImage(im)

        self.canvas.config(width=im.size[0], height=im.size[1])
        self.redraw()

        self.info.config(
            text=f"[{self.idx + 1}/{len(self.targets)}]  {cls}/{name}"
        )

    def redraw(self):
        self.canvas.delete("all")
        self.canvas.create_image(0, 0, anchor="nw", image=self.photo)
        if self.start and self.end:
            self.canvas.create_line(*self.start, *self.end,
                                    fill="#FF3B30", width=5, arrow="last",
                                    arrowshape=(18, 22, 8))
            ang = self.angle_of(self.start, self.end)
            self.canvas.create_text(
                12, 12, anchor="nw",
                text=f"{ang:+.1f}도",
                fill="#FFD60A", font=("Malgun Gothic", 20, "bold"))

    # ---- 마우스 ---------------------------------------------------------
    def on_press(self, e):
        self.start = (e.x, e.y)
        self.end = None

    def on_drag(self, e):
        if self.start:
            self.end = (e.x, e.y)
            self.redraw()

    def on_release(self, e):
        if self.start:
            self.end = (e.x, e.y)
            self.redraw()

    def reset_line(self):
        self.start = self.end = None
        self.redraw()

    # ---- 저장/이동 -------------------------------------------------------
    def write_row(self, status, angle=None):
        cls, name, _ = self.targets[self.idx]
        with open(OUT_CSV, "a", encoding="utf-8", newline="") as f:
            csv.writer(f).writerow([
                cls, name,
                "" if angle is None else f"{angle:.2f}",
                "" if not self.start else self.start[0],
                "" if not self.start else self.start[1],
                "" if not self.end else self.end[0],
                "" if not self.end else self.end[1],
                self.view_size[0], self.view_size[1],
                status,
            ])

    def save_and_next(self):
        if not (self.start and self.end):
            return  # 선을 안 그었으면 저장하지 않는다
        if self.start == self.end:
            return  # 길이 0인 선은 방향이 없다
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
        """직전 이미지로 되돌아간다. CSV의 마지막 줄을 지워 다시 매길 수 있게 한다."""
        if self.idx == 0:
            return
        self.idx -= 1
        self.start = self.end = None
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
    sys.exit(main())
