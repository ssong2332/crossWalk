"""T158: 끝 직진 규칙 (a2)+(e)를 실기기 기록으로 재생해 T146과 비교한다(추정).

`t146_level_replay.py`의 T146 규칙(NewRule)과 재평활·호출 근사를 그대로 쓰고,
T158 규칙만 덧붙인다(`direction_resolver.dart` T158 표):
  - 끝 + |a| < 9 + |p| < 1.5 → front (+ 끝)
  - 끝 + |a| < 9 + |p| >= 1.5 → 방향은 그대로, 단계 계산 각도를 ±12로 줄여 단계 0
지표 정의는 `train/field_1029/report_edge_center.md`(메인 체크아웃, 커밋 안 됨)와 같다:
  - 끝 직진 중앙 쪽 안내: |p| >= 0.8, |a| < 9, 상태가 중앙 쪽 이탈. 진입 수·시간, 그중 단계 >= 1 시간
  - 깊은 끝: |p| >= 1.5로 들어간 사건 수, 그 동안 중앙 쪽 명령이 한 번도 없었던 사건 수
  - 끝 바깥쪽 안내: |p| >= 0.8, 상태가 끝 쪽(바깥쪽) 이탈
  - 바깥으로 흘러감: |p| >= 0.8, 바깥쪽 a >= 12 — 첫 중앙 쪽 명령까지 지연, 명령 없이 끝난 수
시간은 다음 재생 줄까지의 간격(최대 1초)으로 센다. 재생기 구현이 보고서의 scratchpad
`sim_ec.py`와 같지 않으므로 수치는 보고서와 다를 수 있다(추정).

사용(저장소 루트): PYTHONIOENCODING=utf-8 python train/t158_edge_straight_replay.py <log> [<log> ...]
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import t146_level_replay as t146  # noqa: E402

ON = t146.ON
DEV, REC = t146.DEV, t146.REC
STRAIGHT = 9.0
DEEP = 1.5
EDGE_IN = 0.8
GAP_CAP = 1000


class Rule(t146.NewRule):
    def __init__(self, args, t158):
        super().__init__(args)
        self.t158 = t158
        self.name = "T158 (a2)+(e)" if t158 else "현재 T146"

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
        straight = side != 0 and a is not None and abs(a) < STRAIGHT and p is not None
        if self.t158 and straight and abs(p) < DEEP:
            label = "front"
        elif c is None:
            label = prev if prev in ON else "front"
        elif prev == "left" and c >= REC:
            label = "left"
        elif prev == "right" and c <= -REC:
            label = "right"
        elif c >= DEV:
            label = "left"
        elif c <= -DEV:
            label = "right"
        else:
            label = "front"
        held = False
        if label == "front":
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
            if self.t158 and straight and abs(p) >= DEEP and lc is not None and abs(lc) > DEV:
                lc = DEV if lc > 0 else -DEV
            level = self.level_of(lc, prev_lv)
        self.label, self.level = label, level
        return label, edge, level, side


def run(path, rule):
    """t146.run과 같은 근사(재평활 켬, 서 있을 때 0.3) + 각 줄의 a, p를 함께 남긴다."""
    a_sm, p_sm = t146.Smoother(), t146.Smoother()
    a_new = p_new = None
    still = False
    on = False
    seq = []  # (t, label, edge, level, side, a, p)
    for line in open(path, encoding="utf-8"):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        ev, t = e.get("ev"), e.get("t")
        if t is None:
            continue
        if ev == "still" and "on" in e:
            still = bool(e["on"])
            continue
        alpha = rule.alpha_still if still else 0.6
        if ev == "angle":
            raw = e.get("raw")
            if raw is not None:
                a_new = a_sm.add(raw, t, alpha)
        elif ev == "pos":
            raw = e.get("raw")
            if raw is not None:
                p_new = p_sm.add(raw, t, alpha)
        elif ev == "alert":
            on = e.get("cls") in ON
        elif ev == "state" and e.get("to") not in ON:
            on = False
        else:
            continue
        if not on:
            if rule.label != "none":
                rule.reset()
                seq.append((t, "none", False, None, 0, None, None))
            continue
        label, edge, level, side = rule.step(t, a_new, p_new, None, None, still, ev)
        seq.append((t, label, edge, level, side, a_new, p_new))
    return seq


def outward(a, p):
    """바깥쪽으로 틀어진 크기(+면 바깥쪽). 각도는 가야 할 방향이라(T71) 왼쪽 끝에서
    바깥(왼쪽)으로 틀어지면 a가 양수(오른쪽으로 가라)다."""
    return a if p < 0 else -a


def metrics(seq):
    m = dict(es_n=0, es_s=0.0, es_l1=0.0, out_n=0, out_s=0.0,
             deep_n=0, deep_nocmd=0, deep_s=0.0, deep_cmd_s=0.0,
             drift_n=0, drift_nocmd=0, drift_delay=[], lvl_changes=0)
    prev_es = prev_out = False
    deep = None  # 진행 중인 깊은 끝 사건: 명령이 있었는가
    drift = None  # 진행 중인 흘러감 사건: 시작 시각, 명령 시각
    prev_lv = None
    for i, (t, label, edge, level, side, a, p) in enumerate(seq):
        dt = 0.0
        if i + 1 < len(seq):
            dt = min(GAP_CAP, seq[i + 1][0] - t) / 1000.0
        on = label in ON and p is not None
        centerward = None
        if on:
            centerward = "left" if p < 0 else "right"
        center_cmd = on and label == centerward
        # 끝 직진 중앙 쪽 안내
        es = on and a is not None and abs(p) >= EDGE_IN and abs(a) < STRAIGHT and center_cmd
        if es:
            if not prev_es:
                m["es_n"] += 1
            m["es_s"] += dt
            if level is not None and level >= 1:
                m["es_l1"] += dt
        prev_es = es
        # 끝 바깥쪽 안내
        ow = on and abs(p) >= EDGE_IN and label in ("left", "right") and label != centerward
        if ow:
            if not prev_out:
                m["out_n"] += 1
            m["out_s"] += dt
        prev_out = ow
        # 깊은 끝
        if on and abs(p) >= DEEP:
            if deep is None:
                deep = False
                m["deep_n"] += 1
            m["deep_s"] += dt
            if center_cmd:
                deep = True
                m["deep_cmd_s"] += dt
        elif deep is not None:
            if not deep:
                m["deep_nocmd"] += 1
            deep = None
        # 바깥으로 흘러감
        if on and a is not None and abs(p) >= EDGE_IN and outward(a, p) >= DEV:
            if drift is None:
                drift = [t, None]
                m["drift_n"] += 1
            if center_cmd and drift[1] is None:
                drift[1] = t
        elif drift is not None:
            if drift[1] is None:
                m["drift_nocmd"] += 1
            else:
                m["drift_delay"].append(drift[1] - drift[0])
            drift = None
        # 같은 방향 단계 변화
        cur = (label, level)
        if prev_lv is not None and label in ("left", "right") and prev_lv[0] == label \
                and prev_lv[1] != level:
            m["lvl_changes"] += 1
        prev_lv = cur
    if deep is False:
        m["deep_nocmd"] += 1
    if drift is not None:
        if drift[1] is None:
            m["drift_nocmd"] += 1
        else:
            m["drift_delay"].append(drift[1] - drift[0])
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("logs", nargs="+")
    args = ap.parse_args()
    base = argparse.Namespace(hyst=3.0, still_hold=1.5, still_alpha=0.3, no_still=False,
                              step=False, ramp=[0.5, 1.0], gated=False)
    print("| 기록 | 규칙 | 끝 직진 중앙 쪽 안내 (단계≥1 시간) | 깊은 끝 사건 · 명령 없음 | "
          "|p|≥1.5 시간 중 중앙 쪽 명령 | 끝 바깥쪽 안내 | 바깥 흘러감: 사건 · 최대 지연 · 명령 없음 | "
          "같은 방향 단계 변화 |")
    print("|---|---|---|---|---|---|---|---|")
    for log in args.logs:
        for t158 in (False, True):
            rule = Rule(base, t158)
            m = metrics(run(log, rule))
            delay = max(m["drift_delay"]) if m["drift_delay"] else 0
            print(f"| {Path(log).name} | {rule.name} | {m['es_n']}번·{m['es_s']:.1f}초 ({m['es_l1']:.1f}초) | "
                  f"{m['deep_n']} · {m['deep_nocmd']} | {m['deep_cmd_s']:.1f}/{m['deep_s']:.1f}초 | "
                  f"{m['out_n']}번·{m['out_s']:.1f}초 | {m['drift_n']} · {delay}ms · {m['drift_nocmd']} | "
                  f"{m['lvl_changes']} |")


if __name__ == "__main__":
    main()
