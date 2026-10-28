"""T150: 각도 본 라벨링 목록 (413장) 고르기 — 시범 50장 다음 단계, 학습 안 함.

후보 판정은 `t150_select_pilot.py`와 같다 (1,397장). 여기서:
  | 조건                                                     | 처리 |
  |----------------------------------------------------------|------|
  | 시범 50장                                                | 제외 |
  | 이미 고른 사진(시범 포함)과 같은 폴더에서 3초 이내      | 제외 (1초 1장이라 거의 같은 사진) |
  | 나머지                                                   | 아래 구성대로 뽑음 |

구성 (오케스트레이터 승인 A안, 2026-10-28):
  mid(예측 12~30°) 230 (55%) · low(<12°) 95 (23%) · high(≥30°) 95 (23%) = 420
  이유: 시범에서 모델 '중간' 예측 39장의 라벨이 중간 19 / 직진 10 / 큰 10이었다.
  예측 구간이 정답 구간과 크게 다르므로, 중간 예측을 늘리되 양쪽 예측도 섞어
  그 안에 숨은 실제 중간 각도를 찾는다.
  680장이 아닌 이유: 3초 간격을 지키면 남은 후보에서 최대 440장(구간 무시)이다.

실제 결과 (seed 150): 413장 = mid 230 (56%) · low 124 (30%) · high 59 (14%).
  high 는 대부분 mid 프레임 바로 옆(3초 이내)이라 mid 를 먼저 뽑으면 59장만 남는다.
  모자란 몫(36장 중 29장)은 구간 상관없이 남은 후보로 채웠다(전부 low).
  (high 를 먼저 뽑으면 high 96 이지만 mid 가 161로 줄어 중간 비중 목표가 깨진다.)

뽑는 순서: mid 먼저(간격 제약을 가장 덜 받게), 그다음 low, high.
  구간별 몫은 폴더별 후보 수에 비례해 나누고, 폴더 안에서는 횡단 묶음을
  돌아가며 1장씩 (seed 150). 모자라면 다른 폴더에서 채운다.

실행 (저장소 루트, 프레임·기록이 있는 체크아웃 기준):
    python train/t150_select_main.py --root C:/vibecoding/crossWalk
출력: train/t150_main413.csv
"""

import argparse
import csv
import os
import random
import sys
from collections import Counter, defaultdict

from t150_select_pilot import FOLDERS, SEED, candidates, episodes, write

QUOTA = [("mid", 230), ("low", 95), ("high", 95)]
MIN_SEP_MS = 3_000


def far(r, chosen_by_folder):
    return all(abs(r["t_ms"] - t) > MIN_SEP_MS for t in chosen_by_folder[r["folder"]])


ALL = []  # 남은 후보 전체 (main 에서 채움). 이웃 수 계산용


def blocked(r, chosen_by_folder):
    return sum(1 for o in ALL if o is not r and o["folder"] == r["folder"]
               and abs(o["t_ms"] - r["t_ms"]) <= MIN_SEP_MS and far(o, chosen_by_folder))


def take(pool, n, chosen_by_folder, rng):
    """pool 에서 묶음을 돌아가며 최대 n 장."""
    by_ep = defaultdict(list)
    for r in pool:
        by_ep[r["episode"]].append(r)
    eps = sorted(by_ep)
    rng.shuffle(eps)
    got = []
    while len(got) < n and eps:
        for e in list(eps):
            if len(got) >= n:
                break
            cand = [r for r in by_ep[e] if far(r, chosen_by_folder)]
            if not cand:
                eps.remove(e)
                continue
            # 간격 제약으로 막히는 이웃(아직 안 뽑힌 모든 후보)이 가장 적은 사진을 고른다
            r = min(cand, key=lambda x: (blocked(x, chosen_by_folder), rng.random()))
            by_ep[e].remove(r)
            chosen_by_folder[r["folder"]].append(r["t_ms"])
            got.append(r)
    return got


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.dirname(here))
    ap.add_argument("--pilot", default=os.path.join(here, "t150_pilot50.csv"))
    ap.add_argument("--out", default=os.path.join(here, "t150_main413.csv"))
    a = ap.parse_args()

    rows, _ = candidates(a.root)
    episodes(rows)
    with open(a.pilot, encoding="utf-8") as f:
        pilot = {(r["folder"], r["filename"]) for r in csv.DictReader(f)}
    chosen_by_folder = defaultdict(list)
    for r in rows:
        if (r["folder"], r["filename"]) in pilot:
            chosen_by_folder[r["folder"]].append(r["t_ms"])
    rest = [r for r in rows if (r["folder"], r["filename"]) not in pilot]
    if len(pilot) != sum(len(v) for v in chosen_by_folder.values()):
        print("오류: 시범 목록 일부가 후보에 없음", file=sys.stderr)
        return 1

    ALL.extend(rest)
    rng = random.Random(SEED)
    chosen = []
    for b, n in QUOTA:
        pool = [r for r in rest if r["band"] == b]
        size = Counter(r["folder"] for r in pool)
        share = {f: round(n * size[f] / len(pool)) for f in FOLDERS}
        got = []
        for f in FOLDERS:
            got += take([r for r in pool if r["folder"] == f], share[f], chosen_by_folder, rng)
        if len(got) < n:  # 모자라면 남은 후보 전체에서 채운다
            ids = {id(r) for r in got}
            got += take([r for r in pool if id(r) not in ids], n - len(got), chosen_by_folder, rng)
        chosen += got
        if len(got) < n:
            print(f"경고: {b} {n}장 중 {len(got)}장", file=sys.stderr)
    # 간격 때문에 어떤 구간이 모자라면, 남은 몫을 구간 상관없이 남은 후보로 채운다
    total = sum(n for _, n in QUOTA)
    if len(chosen) < total:
        ids = {id(r) for r in chosen}
        extra = take([r for r in rest if id(r) not in ids], total - len(chosen),
                     chosen_by_folder, rng)
        print(f"채움: {len(extra)}장 (" + ", ".join(
            f"{k} {v}" for k, v in Counter(r['band'] for r in extra).items()) + ")")
        chosen += extra

    chosen.sort(key=lambda r: r["t_ms"])
    cols = ["folder", "filename", "t_ms", "log", "state", "model_raw", "band",
            "angle_age_ms", "episode"]
    write(a.out, chosen, cols)

    c = Counter((r["folder"], r["band"]) for r in chosen)
    print(f"본 목록 {len(chosen)}장: " + ", ".join(
        f"{b} {sum(c[(f, b)] for f in FOLDERS)}" for b, _ in QUOTA))
    for f in FOLDERS:
        print(f"  {f}: " + " / ".join(f"{b} {c[(f, b)]}" for b, _ in QUOTA))
    return 0


if __name__ == "__main__":
    sys.exit(main())
