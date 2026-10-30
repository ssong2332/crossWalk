"""T162: 10/30 실기기 반영안(①·③-a·③-b·②)을 실기기 기록으로 재생해 비교한다(추정).

`t146_level_replay.py`의 재평활·호출 근사·끝 뒤집힘 지표(`flips`)를 그대로 쓰고,
규칙만 지금 앱(6395ab0)에 맞춘다:
  - 끝 판정 1.0/0.8, 보정각 c = 각도 + 끝 보정
  - 끝 보정: ramp = |p| 0.5→1.0에서 0→20(지금) / step = 끝일 때만 ±20(③-b)
  - 방향 문턱: 끝 아님 enter/keep(지금 8.5/5.5, ③-a 10/7), 끝 12/9(그대로)
  - T158: 끝 + |a| < 9 + |p| < 1.5 → front, |p| >= 1.5면 단계 계산 각도를 ±12로
  - 단계: 2단계(약 0 / 강 2), 오를 때 up(지금 29, ① 35) / 내릴 때 up − 3
  - 서 있을 때 반대 방향 1.5초 유지(T146 C). b5 = 분류기(alert) 경로 front는 후보를 지우지 않음(②)
지표:
  - 끝↔반대 뒤집힘 (전체 · 끝 안 · **끝 경계**) = `t146.flips` — T146 ② 지표(18→12)
  - 같은 방향 단계 변화, 강(단계 2) 진입 수, 이탈 시간 중 강 비율
재생은 앱 코드(Dart)가 아니라 같은 표를 Python으로 다시 구현한 것이다. 수치는 추정이다.

사용(저장소 루트): PYTHONIOENCODING=utf-8 python train/t162_replay.py <log> [<log> ...]
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import t146_level_replay as t146  # noqa: E402

ON = t146.ON
EDGE_DEV, EDGE_REC = 12.0, 9.0
STRAIGHT, DEEP = 9.0, 1.5
HYST = 3.0
GAP_CAP = 1000


class Rule(t146.NewRule):
    def __init__(self, name, shift="ramp", enter=8.5, keep=5.5, up=29.0, b5=False):
        args = argparse.Namespace(hyst=HYST, still_hold=1.5, still_alpha=0.3, no_still=False,
                                  step=(shift == "step"), ramp=[0.5, 1.0], gated=False)
        super().__init__(args)
        self.name = name
        self.enter, self.keep, self.up, self.b5 = enter, keep, up, b5

    def level_of(self, c, prev):
        if c is None:
            return 0
        m = abs(c)
        u = 2 if m >= self.up else 0
        if prev is None or prev <= u:
            return u
        return 2 if (prev >= 2 and m >= self.up - HYST) else 0

    def step(self, t, a, p, raw_a, raw_p, still, ev):
        still = still and self.use_still
        if ev == "pos":
            s = self.side
            if p is None:
                s = 0
            elif p <= -1.0:
                s = -1
            elif p >= 1.0:
                s = 1
            elif s == -1 and p <= -0.8:
                s = -1
            elif s == 1 and p >= 0.8:
                s = 1
            else:
                s = 0
            self.side = s
        side = self.side
        shift = self.shift(side, p)
        c = (None if side == 0 else shift) if a is None else a + shift
        prev = self.label
        enter, keep = (EDGE_DEV, EDGE_REC) if side != 0 else (self.enter, self.keep)
        straight = side != 0 and a is not None and abs(a) < STRAIGHT and p is not None
        if straight and abs(p) < DEEP:
            label = "front"
        elif c is None:
            label = prev if prev in ON else "front"
        elif prev == "left" and c >= keep:
            label = "left"
        elif prev == "right" and c <= -keep:
            label = "right"
        elif c >= enter:
            label = "left"
        elif c <= -enter:
            label = "right"
        else:
            label = "front"
        held = False
        if label == "front":
            if not (self.b5 and ev == "alert"):
                self.cand = None
        elif self.last_dir is None or self.last_dir == label or not still:
            self.last_dir, self.cand = label, None
        else:
            if self.cand != label:
                self.cand, self.since = label, t
            if t - self.since >= self.hold_ms:
                self.last_dir, self.cand = label, None
            else:
                held = True
                label = prev if (prev in ON and prev != label) else "front"
        centerward = "left" if side < 0 else ("right" if side > 0 else None)
        edge = (not held) and side != 0 and (label == "front" or label == centerward)
        level = None
        if label in ("left", "right"):
            prev_lv = self.level if prev == label else None
            lc = 0.0 if held else c
            if straight and abs(p) >= DEEP and lc is not None and abs(lc) > EDGE_DEV:
                lc = EDGE_DEV if lc > 0 else -EDGE_DEV
            level = self.level_of(lc, prev_lv)
        self.label, self.level = label, level
        return label, edge, level, side


def strong(seq):
    """(강 진입 수, 강 시간, 이탈 시간) — 이탈 시간은 left/right 줄 간격 합(상한 1초)."""
    n = 0
    t2 = tdev = 0.0
    prev_lv = None
    for i, (t, label, edge, level, side, still) in enumerate(seq):
        dt = min(GAP_CAP, seq[i + 1][0] - t) / 1000.0 if i + 1 < len(seq) else 0.0
        if label in ("left", "right"):
            tdev += dt
            if level == 2:
                t2 += dt
                if prev_lv != 2:
                    n += 1
            prev_lv = level
        else:
            prev_lv = None
    return n, t2, tdev


RULES = [
    dict(name="지금 (ramp, 8.5/5.5, 29/26)"),
    dict(name="① 35/32", up=35.0),
    dict(name="③-a 10/7", enter=10.0, keep=7.0),
    dict(name="③-b 끝일 때만 ±20", shift="step"),
    dict(name="② b5", b5=True),
    dict(name="①+③-a+②", up=35.0, enter=10.0, keep=7.0, b5=True),
    dict(name="①+③-a+③-b+②", up=35.0, enter=10.0, keep=7.0, shift="step", b5=True),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("logs", nargs="+")
    args = ap.parse_args()
    print("| 기록 | 규칙 | 끝↔반대 뒤집힘: 전체 (끝 안 · **끝 경계**) | 같은 방향 단계 변화 | 강 진입 | 강 시간 / 이탈 시간 (비율) |")
    print("|---|---|---|---|---|---|")
    for log in args.logs:
        for kw in RULES:
            rule = Rule(**kw)
            seq, _ = t146.run(log, rule, dict(on=True, still=True))
            st = t146.collapse(seq)
            a, b, c = t146.flips(st)
            n2, t2, tdev = strong(seq)
            ratio = 100.0 * t2 / tdev if tdev else 0.0
            print(f"| {Path(log).name} | {rule.name} | {a} ({b} · **{c}**) | {t146.level_changes(seq)} | "
                  f"{n2} | {t2:.1f} / {tdev:.1f}초 ({ratio:.0f}%) |")


if __name__ == "__main__":
    main()
