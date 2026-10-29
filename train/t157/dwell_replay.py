"""T157 P1: 진동 단계 하강 최소 유지(D ms)를 10/28·10/29 기록으로 재생한다(추정).

입력(경고 호출 시점 = alert 줄):
  - 10/29(빌드 939a2d5, T146 반영): alert 줄의 cls·ang(보정각 c)·vibAs를 그대로 쓴다.
    단계 = DirectionResolver.deviationLevel(c, 같은 방향 직전 단계) — 20/30, 내려갈 때 3°.
  - 10/28(이전 빌드): train/t146_level_replay.py의 T146 규칙 재생 결과를 alert 시각에서 뽑는다.
진동 목표: left/right → (방향, 단계), 끝 '이미 틀었음'(front+끝) → (중앙 쪽, 0), front → 직진,
그 밖(none/approach/crossed/hold) → 바로 멈춤. 앱의 VibrationLevelDwell과 같은 규칙을
경고 호출 시점에만 적용한다. 박자(진동 펄스)는 단계 간격 600/350/300ms 타이머로 흉내 낸다.
TTS 때문에 딩이 미뤄지는 것(T147)은 넣지 않았다.

사용(메인 checkout 최상위에서):
  PYTHONIOENCODING=utf-8 python <worktree>/train/t157/dwell_replay.py \
      logs/log_20261029_161443.jsonl "logs/crosswalk log 18e954a.txt"
"""
import argparse
import json
import os
import statistics as st
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import t146_level_replay as t146  # noqa: E402

INTERVAL = {0: 600, 1: 350, 2: 300}


def level_of(c, prev, h=3.0):
    if c is None:
        return 0
    m = abs(c)
    up = 2 if m >= 30 else (1 if m >= 20 else 0)
    if prev is None or prev <= up:
        return up
    if prev >= 2 and m >= 30 - h:
        return 2
    if m >= 20 - h:
        return 1
    return 0


def targets_1029(path):
    out = []
    last_cls, last_lv = None, None
    for line in open(path, encoding="utf-8"):
        if '"ev":"alert"' not in line:
            if '"ev":"state"' in line and '"to":"hold"' in line:
                out.append((json.loads(line)["t"], "X"))
                last_cls = None
            continue
        e = json.loads(line)
        cls, t = e.get("cls"), e["t"]
        if cls in ("left", "right"):
            prev = last_lv if last_cls == cls else None
            lv = level_of(e.get("ang"), prev)
            last_cls, last_lv = cls, lv
            out.append((t, (cls, lv)))
        else:
            last_cls = None
            if cls == "front" and e.get("vibAs"):
                out.append((t, (e["vibAs"], 0)))
            elif cls == "front":
                out.append((t, "F"))
            else:
                out.append((t, "X"))
    return out


def targets_1028(path):
    class A:
        hyst, still_hold, still_alpha, ramp = 3.0, 1.5, 0.3, [0.5, 1.0]
        step = gated = no_still = False
    alert_t, hold_t = set(), []
    for line in open(path, encoding="utf-8"):
        if '"ev":"alert"' in line:
            alert_t.add(json.loads(line)["t"])
        elif '"ev":"state"' in line and '"to":"hold"' in line:
            hold_t.append(json.loads(line)["t"])
    seq, _ = t146.run(path, t146.NewRule(A()), dict(on=True, still=True))
    out, seen = [], set()
    for t, label, edge, level, side, still in seq:
        if t not in alert_t or t in seen:
            continue
        seen.add(t)
        if label in ("left", "right"):
            out.append((t, (label, level)))
        elif label == "front" and edge:
            out.append((t, ("left" if side < 0 else "right", 0)))
        elif label == "front":
            out.append((t, "F"))
        else:
            out.append((t, "X"))
    out += [(t, "X") for t in hold_t]
    out.sort(key=lambda x: x[0])
    return out


class Dwell:
    """lib/services/vibration_level_dwell.dart와 같은 규칙. d=0이면 종전(바로)."""

    def __init__(self, d, all_lvl0=False):
        self.d, self.all0 = d, all_lvl0
        self.reset()

    def reset(self):
        self.cls, self.lv, self.since, self.desc = None, 0, None, False

    def resolve(self, tgt, t):
        """tgt: (cls, lv) 또는 None(직진). 반환 (cls, lv) 또는 None."""
        if self.d == 0:  # 종전: 판정 그대로
            self.cls, self.lv = (tgt[0], tgt[1]) if tgt else (None, 0)
            return tgt
        if self.cls is None:
            if tgt:
                self.cls, self.lv, self.since, self.desc = tgt[0], tgt[1], t, False
            return (self.cls, self.lv) if self.cls else None
        if tgt and (tgt[0] != self.cls or tgt[1] >= self.lv):
            if tgt[0] != self.cls or tgt[1] != self.lv:
                self.cls, self.lv, self.since, self.desc = tgt[0], tgt[1], t, False
            return (self.cls, self.lv)
        if tgt is None and self.lv == 0 and not self.desc and not self.all0:
            self.reset()
            return None
        if t - self.since >= self.d:
            if self.lv > 0:
                self.lv, self.since, self.desc = self.lv - 1, t, True
            else:
                self.reset()
                return None
        return (self.cls, self.lv)


def simulate(tg, d, all0=False):
    dw = Dwell(d, all0)
    segs, recovers, pulses = [], [], []
    cur, cur_t, straight_t, last_pulse = None, None, None, None
    for t, tgt in tg:
        if tgt == "X":
            dw.reset()
            o, straight_t = None, None
        elif tgt == "F":
            if straight_t is None:
                straight_t = t
            o = dw.resolve(None, t)
        else:
            straight_t = None
            o = dw.resolve(tgt, t)
        if cur is not None and last_pulse is not None:
            while last_pulse + INTERVAL[cur[1]] < t:
                last_pulse += INTERVAL[cur[1]]
                pulses.append((last_pulse, cur))
        if o != cur:
            if cur is not None:
                segs.append((cur_t, t, cur[0], cur[1]))
            if o is not None and (cur is None or o[0] != cur[0]):
                last_pulse = t
                pulses.append((t, o))
            elif o is not None and t - last_pulse >= INTERVAL[o[1]]:
                last_pulse = t
                pulses.append((t, o))
            if o is None:
                if cur is not None and tgt == "F":
                    recovers.append((t, straight_t))
                last_pulse = None
            cur, cur_t = o, t
    return segs, recovers, pulses


def descents(segs):
    """같은 방향으로 이어진 출력 구간 묶음 중 단계 2를 지난 것."""
    eps, ep = [], []
    for s in segs:
        if ep and (s[2] != ep[-1][2] or s[0] != ep[-1][1]):
            eps.append(ep)
            ep = []
        ep.append(s)
    if ep:
        eps.append(ep)
    n2 = full = 0
    dw = {0: [], 1: []}
    for ep in eps:
        lv = [s[3] for s in ep]
        if 2 not in lv:
            continue
        n2 += 1
        tail = lv[lv.index(2):]
        if any(tail[k:k + 3] == [2, 1, 0] for k in range(len(tail))):
            full += 1
        for k in range(1, len(ep)):
            if ep[k][3] < ep[k - 1][3]:
                dw[ep[k][3]].append(ep[k][1] - ep[k][0])
    return n2, full, dw


def med(x):
    return f"{st.median(x):.0f}" if x else "-"


def pct(x, q):
    if not x:
        return "-"
    x = sorted(x)
    return f"{x[min(len(x) - 1, int(q * len(x)))]:.0f}"


def report(name, tg):
    base_rec = len(simulate(tg, 0)[1])
    print(f"\n## {name} (경고 호출 {len(tg)}번)")
    print("| D | 단계 2 묶음 | 2→1→0 | 하강 lvl1 체류 중앙 (n) | 하강 lvl0 체류 중앙 (n) | 하강 lvl0 ≤400ms | "
          "직진 확인 수 (종전 대비) | 늦어진 수 | 늦어짐 중앙 / 90% / 최대 ms | "
          "안 b(딩=직진 판정 순간): 딩 뒤 방향 펄스가 이어진 확인 / 펄스 수 |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for d, all0 in ((0, False), (500, False), (700, False), (900, False), (700, True)):
        segs, rec, pulses = simulate(tg, d, all0)
        n2, full, dw = descents(segs)
        delayed = [r[0] - r[1] for r in rec if r[1] is not None and r[0] > r[1]]
        after = npul = 0
        for r_t, s_t in rec:
            if s_t is None or r_t <= s_t:
                continue
            k = sum(1 for p, _ in pulses if s_t < p < r_t)
            npul += k
            after += k > 0
        lab = "종전(바로)" if d == 0 else (f"{d}" + (" + 처음부터 lvl0도 유지" if all0 else ""))
        print(f"| {lab} | {n2} | {full} | {med(dw[1])} ({len(dw[1])}) | {med(dw[0])} ({len(dw[0])}) | "
              f"{sum(1 for x in dw[0] if x <= 400)} | {len(rec)} ({len(rec) - base_rec:+d}) | {len(delayed)} | "
              f"{med(delayed)} / {pct(delayed, 0.9)} / {max(delayed) if delayed else '-'} | {after} / {npul} |")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("log1029")
    ap.add_argument("log1028")
    a = ap.parse_args()
    report("10/29 (alert 줄 그대로)", targets_1029(a.log1029))
    report("10/28 (T146 규칙 재생)", targets_1028(a.log1028))
