"""T150: 각도 재학습 시범 라벨링용 50장 고르기 (학습 안 함).

T144(`train/field_1028/report_angle.md` §4-2)의 재학습 후보 1,397장을 다시 계산하고,
그중 시범 50장을 고른다.

후보 판정 (프레임 f_<epoch ms>.jpg 하나마다):
  | 조건                                                    | 처리          |
  |---------------------------------------------------------|---------------|
  | 프레임 시각이 아래 5개 기록의 시간 범위 어디에도 없음   | 제외 (nolog)  |
  | 직전 state 이벤트의 to 가 front/left/right 가 아님      | 제외          |
  | 직전 angle 이벤트 raw 가 없음                           | 제외          |
  | 나머지                                                  | 후보 (1,397)  |
  구간(모델 예측 |raw|): low <12 · mid 12~30 · high ≥30  (A안 경계 12/30)

시범 50장 (seed 150, 같은 입력이면 같은 결과):
  - 날짜 폴더 5개 × (mid 8 + low 1 + high 1) = 50
  - 장소 정보(GPS)는 기록에 없다. 대신 '횡단 묶음'(후보 프레임 사이 간격 >10초면
    새 묶음)을 장소·횡단의 대용으로 쓰고, 묶음을 돌아가며 1장씩 뽑는다.
  - 이미 뽑은 프레임과 3초 이내인 프레임은 뽑지 않는다 (1초 1장이라 거의 같은 사진).

실행 (저장소 루트에서, 프레임·기록이 있는 체크아웃):
    python train/t150_select_pilot.py --root C:/vibecoding/crossWalk
출력: train/t150_candidates.csv (1,397행), train/t150_pilot50.csv (50행)
"""

import argparse
import bisect
import csv
import json
import os
import random
import sys
from collections import Counter, defaultdict

# 폴더 -> 그 폴더 프레임을 덮는 기록 (T144 §4-2 와 같은 5개)
FOLDERS = ["frames_1025", "frames_1025b", "frames_1026", "frames_1027", "frames_1028b"]
LOGS = [
    "logs/log_20261025_113155.jsonl",
    "logs/crosswalk log 0d1eb91.txt",
    "logs/log_20261026_213316.jsonl",
    "logs/log_20261027_121630.jsonl",
    "logs/crosswalk log 18e954a.txt",
]
ON_STATES = ("front", "left", "right")
MID_LO, MID_HI = 12.0, 30.0
QUOTA = {"mid": 8, "low": 1, "high": 1}
EPISODE_GAP_MS = 10_000
MIN_SEP_MS = 3_000
SEED = 150


def band(a):
    if a < MID_LO:
        return "low"
    return "mid" if a < MID_HI else "high"


def read_log(path):
    states, angles, lo, hi = [], [], None, None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if not line.startswith("{"):
                continue
            try:
                e = json.loads(line)
            except ValueError:
                continue
            t = e.get("t")
            if t is None:
                continue
            lo = t if lo is None else min(lo, t)
            hi = t if hi is None else max(hi, t)
            if e.get("ev") == "state":
                states.append((t, e.get("to")))
            elif e.get("ev") == "angle":
                angles.append((t, e.get("raw")))
    states.sort()
    angles.sort()
    return {"path": path, "lo": lo, "hi": hi, "states": states, "angles": angles,
            "st_t": [t for t, _ in states], "an_t": [t for t, _ in angles]}


def candidates(root):
    logs = [read_log(os.path.join(root, p)) for p in LOGS]
    rows, stat = [], Counter()
    for folder in FOLDERS:
        for name in sorted(os.listdir(os.path.join(root, "train", folder))):
            if not (name.startswith("f_") and name.endswith(".jpg")):
                continue
            t = int(name[2:-4])
            lg = next((g for g in logs if g["lo"] <= t <= g["hi"]), None)
            if lg is None:
                stat["nolog"] += 1
                continue
            i = bisect.bisect_right(lg["st_t"], t) - 1
            j = bisect.bisect_right(lg["an_t"], t) - 1
            state = lg["states"][i][1] if i >= 0 else None
            if state not in ON_STATES:
                continue
            raw = lg["angles"][j][1] if j >= 0 else None
            if raw is None:
                stat["noangle"] += 1
                continue
            rows.append({
                "folder": folder, "filename": name, "t_ms": t,
                "log": os.path.basename(lg["path"]), "state": state,
                "model_raw": round(raw, 2), "band": band(abs(raw)),
                "angle_age_ms": t - lg["angles"][j][0],
            })
    return rows, stat


def episodes(rows):
    """폴더 안 후보를 시간순으로 묶음 번호를 붙인다."""
    by_folder = defaultdict(list)
    for r in rows:
        by_folder[r["folder"]].append(r)
    for rs in by_folder.values():
        rs.sort(key=lambda r: r["t_ms"])
        ep, prev = 0, None
        for r in rs:
            if prev is not None and r["t_ms"] - prev > EPISODE_GAP_MS:
                ep += 1
            r["episode"] = ep
            prev = r["t_ms"]


def pick(rows):
    rng = random.Random(SEED)
    chosen = []
    for folder in FOLDERS:
        for b, n in QUOTA.items():
            pool = [r for r in rows if r["folder"] == folder and r["band"] == b]
            by_ep = defaultdict(list)
            for r in pool:
                by_ep[r["episode"]].append(r)
            eps = sorted(by_ep)
            rng.shuffle(eps)
            got = 0
            while got < n and any(by_ep[e] for e in eps):
                for e in eps:
                    if got >= n:
                        break
                    cand = [r for r in by_ep[e]
                            if all(abs(r["t_ms"] - c["t_ms"]) > MIN_SEP_MS for c in chosen)]
                    if not cand:
                        by_ep[e] = []
                        continue
                    r = rng.choice(cand)
                    by_ep[e].remove(r)
                    chosen.append(r)
                    got += 1
            if got < n:
                print(f"경고: {folder} {b} {n}장 중 {got}장만 뽑힘", file=sys.stderr)
    chosen.sort(key=lambda r: r["t_ms"])
    return chosen


def write(path, rows, cols):
    with open(path, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    help="frames_*·logs 가 있는 저장소 루트")
    ap.add_argument("--out", default=os.path.dirname(os.path.abspath(__file__)))
    a = ap.parse_args()

    rows, stat = candidates(a.root)
    episodes(rows)
    chosen = pick(rows)

    cols = ["folder", "filename", "t_ms", "log", "state", "model_raw", "band",
            "angle_age_ms", "episode"]
    write(os.path.join(a.out, "t150_candidates.csv"), rows, cols)
    write(os.path.join(a.out, "t150_pilot50.csv"), chosen, cols)

    print(f"후보 {len(rows)}장 (제외: 기록 없음 {stat['nolog']}, 각도 없음 {stat['noangle']})")
    c = Counter((r["folder"], r["band"]) for r in rows)
    for f in FOLDERS:
        n_ep = len({r["episode"] for r in rows if r["folder"] == f})
        print(f"  {f}: low {c[(f, 'low')]} / mid {c[(f, 'mid')]} / high {c[(f, 'high')]}  묶음 {n_ep}")
    print(f"시범 {len(chosen)}장: " + ", ".join(f"{k} {v}" for k, v in Counter(r['band'] for r in chosen).items()))
    print(f"  묶음 수(폴더별 서로 다른 묶음): " + ", ".join(
        f"{f} {len({r['episode'] for r in chosen if r['folder'] == f})}" for f in FOLDERS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
