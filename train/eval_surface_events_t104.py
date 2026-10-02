"""T104: 노면 안내 판정표(`docs/SurfaceGuidance.md`)의 **이벤트 단위** 평가.

test 분할(폴더 단위 홀드아웃, 4,718장)에서 폴더마다 파일 번호 순서를 걷는 순서로 보고,
같은 규칙을 정답 마스크와 예측 마스크에 각각 적용해 나온 이벤트를 비교한다.

근사 (실제 앱과 다름 — 결과 해석 시 주의):
  - 시간 -> 사진 장수: 직전 3초 -> 직전 3장, 2초 -> 2장, 재무장 3초 -> 3장.
  - 분류기 상태 조건(none/crossed에서만 활성)은 빼고 모든 사진을 활성으로 본다.
  - 사진 간격이 실제 보행 간격과 같은지 모른다(AI Hub 수집 방식 미확인).
맞음 판정: 같은 종류의 정답 이벤트가 ±TOL장 안에 있으면 맞음(한 정답에 한 예측만).

이벤트(판정표 행 번호):
  road_trans (1) 인도 -> 차도 전이   road_first (2) 전이 없이 처음 차도
  dot_appear (3) 멈춤 블록 등장
  lin_right (6) / lin_left (7) 선형이 옆으로 벗어남   lin_lost (8) 선형을 벗어남

실행: python train/eval_surface_events_t104.py
출력: train/surface_events_t104.log (표준출력), train/surface_events_t104.json
"""
import csv
import json
import os
import sys
from collections import defaultdict

import numpy as np
import onnxruntime as ort
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import train_seg_t104 as T  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ONNX = os.path.join(REPO, "model", "crosswalk_surface_t104.onnx")
OUT = os.path.join(REPO, "train", "surface_events_t104.json")
TOL = 2
S = T.SIZE
ROWS = slice(S // 2, S)
COLS = {"L": slice(0, S // 3), "F": slice(S // 3, 2 * S // 3), "R": slice(2 * S // 3, S)}
SIDEWALK, ROAD, LIN, DOT = 1, 2, 4, 5


def features(mask):
    f = {}
    for k, c in COLS.items():
        reg = mask[ROWS, c]
        n = reg.size
        f[k] = {cls: float((reg == cls).sum()) / n for cls in (SIDEWALK, ROAD, LIN, DOT)}
    return f


class Debounce:
    """같은 값이 2번 연속일 때만 바뀌는 불리언(판정표 §2 연속 확인)."""

    def __init__(self):
        self.value, self.cand, self.n = False, None, 0

    def update(self, x):
        if x == self.value:
            self.cand, self.n = None, 0
            return False
        if x == self.cand:
            self.n += 1
        else:
            self.cand, self.n = x, 1
        if self.n >= 2:
            self.value, self.cand, self.n = x, None, 0
            return True
        return False


def events(seq):
    """특징 시퀀스 -> [(index, type)]. 판정표 행 1·2·3·6·7·8."""
    road, side, dot, lin_f = Debounce(), Debounce(), Debounce(), Debounce()
    out = []
    last_side = -99       # 인도 많음이 안정적으로 참이었던 마지막 장
    road_off, dot_off = 99, 99   # 거짓이 이어진 장 수(재무장용)
    road_armed, dot_armed = True, True
    on_line, lost = False, 0
    for i, f in enumerate(seq):
        F, L, R = f["F"], f["L"], f["R"]
        side.update(F[SIDEWALK] >= 0.5)
        if side.value:
            last_side = i
        if road.update(F[ROAD] >= 0.5) and road.value:
            if i - last_side <= 3:
                out.append((i, "road_trans"))
            elif road_armed:
                out.append((i, "road_first"))
            road_armed = False
        road_off = 0 if road.value else road_off + 1
        if road_off >= 3:
            road_armed = True
        if dot.update(F[DOT] >= 0.05) and dot.value and dot_armed:
            out.append((i, "dot_appear"))
            dot_armed = False
        dot_off = 0 if dot.value else dot_off + 1
        if dot_off >= 3:
            dot_armed = True
        changed = lin_f.update(F[LIN] >= 0.05)
        if lin_f.value:
            on_line, lost = True, 0
        elif on_line:
            if changed and R[LIN] >= 0.05:
                out.append((i, "lin_right"))
                on_line = False
            elif changed and L[LIN] >= 0.05:
                out.append((i, "lin_left"))
                on_line = False
            elif L[LIN] < 0.05 and R[LIN] < 0.05:
                lost += 1
                if lost >= 2:
                    out.append((i, "lin_lost"))
                    on_line = False
            else:
                lost = 0
    return out


def match(gt, pr):
    """종류별 탐욕 매칭(±TOL). 반환: {종류: [tp, n_gt, n_pred]}."""
    res = defaultdict(lambda: [0, 0, 0])
    for t in {e[1] for e in gt} | {e[1] for e in pr}:
        g = sorted(i for i, k in gt if k == t)
        p = sorted(i for i, k in pr if k == t)
        used = set()
        tp = 0
        for gi in g:
            best = None
            for j, pi in enumerate(p):
                if j not in used and abs(pi - gi) <= TOL:
                    if best is None or abs(pi - gi) < abs(p[best] - gi):
                        best = j
            if best is not None:
                used.add(best)
                tp += 1
        res[t] = [tp, len(g), len(p)]
    return res


def main():
    with open(os.path.join(T.CACHE, "index.csv"), encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    test = set(T.split_folders(rows)["test"])
    by_folder = defaultdict(list)
    for r in rows:
        if r["key"] in test:
            by_folder[r["folder"]].append(r["key"])
    sess = ort.InferenceSession(ONNX, providers=["CPUExecutionProvider"])
    ds = T.SegSet([], False)
    total = defaultdict(lambda: [0, 0, 0])
    n_img = 0
    for folder, keys in sorted(by_folder.items()):
        keys.sort()
        ds.keys = keys
        gt_seq, pr_seq = [], []
        for i in range(len(keys)):
            x, y = ds[i]
            p = sess.run(None, {"input": x.numpy()[None]})[0][0].argmax(0)
            gt_seq.append(features(y.numpy()))
            pr_seq.append(features(p))
        n_img += len(keys)
        for t, (tp, g, q) in match(events(gt_seq), events(pr_seq)).items():
            total[t][0] += tp
            total[t][1] += g
            total[t][2] += q
    names = {"road_trans": "1 인도→차도 전이", "road_first": "2 전이 없이 처음 차도",
             "dot_appear": "3 멈춤 블록 등장", "lin_right": "6 선형 오른쪽으로 벗어남",
             "lin_left": "7 선형 왼쪽으로 벗어남", "lin_lost": "8 선형 벗어남"}
    print(f"test 폴더 {len(by_folder)}개, 사진 {n_img}장, 맞음 허용 ±{TOL}장")
    print(f"{'이벤트':22s} {'정답':>5s} {'예측':>5s} {'맞음':>5s} {'재현율':>8s} {'정밀도':>8s}")
    for t in names:
        tp, g, q = total.get(t, [0, 0, 0])
        rec = f"{tp / g * 100:.1f}%" if g else "-"
        pre = f"{tp / q * 100:.1f}%" if q else "-"
        print(f"{names[t]:22s} {g:5d} {q:5d} {tp:5d} {rec:>8s} {pre:>8s}")
    json.dump({"tol": TOL, "folders": len(by_folder), "images": n_img,
               "events": {t: total.get(t, [0, 0, 0]) for t in names}},
              open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
