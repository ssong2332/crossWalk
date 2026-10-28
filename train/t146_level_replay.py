"""T146: 이탈 단계 재설계(A~C)를 10/28 실기기 기록으로 재생해 전후를 비교한다(추정).

기록의 angle/pos/alert/still 줄을 시간 순서대로 넣어 두 규칙으로 상태·단계를 다시 계산한다.
  - 이전(18e954a, T143까지): 기록의 평활값 그대로, 끝이면 ±20/0, 이미 틀었음 12~25(25/21·12/9),
    단계 = 끝 2 / |각도|>=25 1(내려갈 때 2초 래치) / 0.
  - T146: raw로 다시 평활(걸을 때 0.6, 서 있을 때 0.3), 끝 판정 1.0/0.8, 보정각 c = a ± 20,
    방향 12/9, 단계 20/30(내려갈 때 3° 아래), 서 있을 때 반대 방향 1.5초.
앱의 실제 호출 시점(분류·각도·위치 경로)을 기록 줄로 근사하므로 수치는 추정이다.

사용: PYTHONIOENCODING=utf-8 python train/t146_level_replay.py "logs/crosswalk log 18e954a.txt"
     [--hyst 3] [--still-hold 1.5] [--still-alpha 0.3]
"""
import argparse
import json
import re

ON = {"front", "left", "right"}
DEV, REC = 12.0, 9.0
STEER = 20.0

# 10/28 보고서 §2의 '이탈 중 직진' 장면 27개(프레임 파일 시각, 원인)
SCENES = [
    ("S01", 1793172568739, "끝 규칙"), ("S02", 1793172641802, "끝 규칙"),
    ("S03", 1793172760561, "끝 규칙"), ("S04", 1793173169294, "끝 규칙"),
    ("S05", 1793173390600, "끝 규칙"), ("S06", 1793173420512, "끝 규칙"),
    ("S07", 1793173956028, "끝 규칙"), ("S08", 1793173983033, "끝 규칙"),
    ("S09", 1793173999455, "끝 규칙"), ("S10", 1793174020134, "끝 규칙"),
    ("S11", 1793172776149, "평활 지연"), ("S12", 1793173190550, "평활 지연"),
    ("S13", 1793173379356, "평활 지연"), ("S14", 1793173388563, "평활 지연"),
    ("S15", 1793173656529, "평활 지연"), ("S16", 1793173966520, "평활 지연"),
    ("S17", 1793174055243, "평활 지연"),
    ("S18", 1793173176795, "기준 근처"), ("S19", 1793173771620, "기준 근처"),
    ("S20", 1793173781871, "기준 근처"), ("S21", 1793174060283, "기준 근처"),
    ("S22", 1793172570864, "모델 오차"), ("S23", 1793172582203, "모델 오차"),
    ("S24", 1793173378301, "모델 오차"),
    ("S25", 1793172927782, "전환 중"), ("S26", 1793173773715, "전환 중"),
    ("S27", 1793173974804, "전환 중"),
]


# ---------------------------------------------------------------- 이전 규칙 (5fbb58c)
class OldRule:
    name = "이전(18e954a)"

    def __init__(self, args):
        self.reset()

    def reset(self):
        self.label, self.edge = "none", False
        self.sev_rep, self.sev_seen = False, False
        self.sev_pend, self.sev_since = None, None
        self.sev_cls = None

    def steer(self, p, a):
        if p is None:
            return None
        if p <= -1.0:
            cw, over, out = -1.0, "right", STEER
        elif p >= 1.0:
            cw, over, out = 1.0, "left", -STEER
        else:
            return None
        m = None if a is None else cw * a
        cap = 21.0 if self.label == over else 25.0
        if m is not None and m > cap:
            return None
        low = 9.0 if (self.label == "front" and self.edge) else DEV
        return 0.0 if (m is not None and m >= low) else out

    def step(self, t, a_log, p_log, raw_a, raw_p, still, ev):
        a, p = a_log, p_log
        s = self.steer(p, a)
        if s is not None:
            label = "front" if s == 0 else ("left" if s > 0 else "right")
            edge = True
            ang = s
        else:
            edge = False
            ang = a
            prev = self.label
            if a is None:
                label = prev if prev in ON else "front"
            elif prev == "left" and a >= REC:
                label = "left"
            elif prev == "right" and a <= -REC:
                label = "right"
            elif a >= DEV:
                label = "left"
            elif a <= -DEV:
                label = "right"
            else:
                label = "front"
        level = None
        if label in ("left", "right"):
            if self.sev_cls is not None and self.sev_cls != label:
                self._sev_reset()
            self.sev_cls = label
            severe = self._sev_update(ang is not None and abs(ang) >= 25.0, t)
            level = 2 if edge else (1 if severe else 0)
        else:
            self._sev_reset()
            self.sev_cls = None
        self.label, self.edge = label, edge
        side = 0 if p is None else (-1 if p <= -1.0 else (1 if p >= 1.0 else 0))
        return label, edge, level, side

    def _sev_reset(self):
        self.sev_rep, self.sev_seen, self.sev_pend, self.sev_since = False, False, None, None

    def _sev_update(self, raw, t):
        if not self.sev_seen:
            self.sev_seen, self.sev_rep = True, raw
            return raw
        if raw == self.sev_rep:
            self.sev_pend = None
            return raw
        if raw:
            self.sev_rep, self.sev_pend = True, None
            return True
        if self.sev_pend != raw:
            self.sev_pend, self.sev_since = raw, t
        if t - self.sev_since >= 2000:
            self.sev_rep, self.sev_pend = raw, None
        return self.sev_rep


# ---------------------------------------------------------------- T146 규칙
class NewRule:
    name = "T146"

    def __init__(self, args):
        self.h = args.hyst
        self.hold_ms = args.still_hold * 1000
        self.alpha_still = args.still_alpha
        self.use_still = not args.no_still
        self.reset()

    def reset(self):
        self.label = "none"
        self.level = None
        self.side = 0
        self.last_dir = None
        self.cand, self.since = None, None

    def level_of(self, c, prev):
        if c is None:
            return 0
        m = abs(c)
        up = 2 if m >= 30 else (1 if m >= 20 else 0)
        if prev is None or prev <= up:
            return up
        if prev >= 2 and m >= 30 - self.h:
            return 2
        if m >= 20 - self.h:
            return 1
        return 0

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
        c = (None if side == 0 else -side * STEER) if a is None else a - side * STEER
        prev = self.label
        if c is None:
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
        # 서 있을 때 반대 방향 지연
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
            level = self.level_of(0.0 if held else c, prev_lv)
        self.label, self.level = label, level
        return label, edge, level, side


# ---------------------------------------------------------------- 재생
class Smoother:
    def __init__(self):
        self.v = None
        self.last_t = None

    def add(self, raw, t, alpha):
        if self.last_t is not None and t - self.last_t > 1200:
            self.v = None  # 3번 무판정(약 1초)이면 스무더가 비워진다
        self.last_t = t
        self.v = raw if self.v is None else self.v + (raw - self.v) * alpha
        return self.v


def run(path, rule, resmooth):
    a_log = p_log = None
    a_sm, p_sm = Smoother(), Smoother()
    a_new = p_new = None
    still = False
    on = False
    seq = []  # (t, label, edge, level, side, still)
    agree = n_alert = 0
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
        alpha = rule.alpha_still if (still and resmooth.get("still")) else 0.6
        if ev == "angle":
            a_log = e.get("smooth")
            raw = e.get("raw")
            if raw is not None and resmooth.get("on"):
                a_new = a_sm.add(raw, t, alpha)
        elif ev == "pos":
            p_log = e.get("smooth")
            raw = e.get("raw")
            if raw is not None and resmooth.get("on"):
                p_new = p_sm.add(raw, t, alpha)
        elif ev == "alert":
            on = e.get("cls") in ON
            logged = (e.get("cls"), bool(e.get("edge")))
        elif ev == "state" and e.get("to") not in ON:
            on = False
        else:
            continue
        if not on:
            if rule.label != "none":
                rule.reset()
                seq.append((t, "none", False, None, 0, still))
            continue
        a = a_new if resmooth.get("on") else a_log
        p = p_new if resmooth.get("on") else p_log
        label, edge, level, side = rule.step(t, a, p, None, None, still, ev)
        if ev == "alert":
            n_alert += 1
            if (label, edge) == logged:
                agree += 1
        seq.append((t, label, edge, level, side, still))
    return seq, (agree, n_alert)


def kind(label, edge, level, side):
    if label == "none":
        return "none"
    if label == "front":
        if edge:
            return "TL" if side < 0 else "TR"
        return "F"
    d = "L" if label == "left" else "R"
    return f"{d}{level}"


def collapse(seq):
    out = []
    for t, label, edge, level, side, still in seq:
        k = kind(label, edge, level, side)
        if not out or out[-1][1] != k:
            out.append((t, k, side, still, edge))
    return out


def descent(states):
    """단계 2 묶음마다 이어진 같은 방향 경로를 분류한다."""
    res = dict(runs=0, full=0, to1=0, to0=0, toF=0, toT=0, toOpp=0, toNone=0, paths=[])
    i = 0
    n = len(states)
    while i < n:
        t, k, side, still, edge = states[i]
        if k in ("L2", "R2"):
            d = k[0]
            res["runs"] += 1
            j = i + 1
            path = []
            while j < n and states[j][1] in (d + "1", d + "0", d + "2"):
                if states[j][1] == d + "2":
                    break
                path.append(states[j][1])
                j += 1
            if j < n and states[j][1] == d + "2":
                # 다시 2로 올라감 — 새 묶음으로 센다(이 묶음의 경로는 중간까지)
                pass
            nxt = states[j][1] if j < n else "end"
            has1 = (d + "1") in path
            has0 = has1 and (d + "0") in path[path.index(d + "1"):]
            if has1 and has0:
                res["full"] += 1
            elif has1:
                res["to1"] += 1
            elif (d + "0") in path:
                res["to0"] += 1
            elif nxt == "F":
                res["toF"] += 1
            elif nxt in ("TL", "TR"):
                res["toT"] += 1
            elif nxt[:1] in ("L", "R") and nxt[:1] != d:
                res["toOpp"] += 1
            else:
                res["toNone"] += 1
            res["paths"].append((t, k, path, nxt))
            i = j
        else:
            i += 1
    return res


def flips(states, t_from=None, t_to=None):
    """끝 상태(중앙 쪽 이탈 + 끝, 또는 이미 틀었음) ↔ 반대 방향 이탈 직접 전환 횟수.
    (전체, 끝 안에서(전후 끝 판정이 같은 쪽), 끝을 나오거나 들어오며)로 돌려준다."""
    n = inside = 0
    for (t0, k0, s0, _, e0), (t1, k1, s1, _, e1) in zip(states, states[1:]):
        if t_from is not None and not (t_from <= t1 <= t_to):
            continue
        for (ka, sa, ea), (kb, sb, eb) in (((k0, s0, e0), (k1, s1, e1)), ((k1, s1, e1), (k0, s0, e0))):
            if not ea or sa == 0:
                continue
            opp = "R" if sa < 0 else "L"  # 왼쪽 끝이면 반대 = right 이탈(R)
            if kb[:1] == opp and kb[1:].isdigit():
                n += 1
                if s0 == s1:
                    inside += 1
                break
    return n, inside, n - inside


def fmt_flips(st, loop):
    a, b, c = flips(st)
    la = flips(st, *loop)[0]
    return f"{a} (끝 안 {b} · 끝 경계 {c}) / 구간 {la}"


def state_at(seq, t):
    last = None
    for row in seq:
        if row[0] > t:
            break
        last = row
    return last


def level_changes(seq):
    n = 0
    prev = None
    for t, label, edge, level, side, still in seq:
        cur = (label, level)
        if prev is not None and label in ("left", "right") and prev[0] == label and prev[1] != level:
            n += 1
        prev = cur
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--hyst", type=float, default=3.0)
    ap.add_argument("--still-hold", type=float, default=1.5)
    ap.add_argument("--still-alpha", type=float, default=0.3)
    ap.add_argument("--no-still", action="store_true", help="C(서 있을 때 처리)를 끈 T146")
    ap.add_argument("--paths", action="store_true")
    args = ap.parse_args()

    loop = (1793173951000, 1793174024999)  # 16:52:31~16:53:44 (보고서 §3)
    rows = []
    old = OldRule(args)
    seq_o, ag_o = run(args.log, old, dict(on=False))
    new = NewRule(args)
    seq_n, ag_n = run(args.log, new, dict(on=True, still=not args.no_still))
    for name, seq, ag in ((old.name, seq_o, ag_o), (new.name, seq_n, ag_n)):
        st = collapse(seq)
        d = descent(st)
        rows.append((name, seq, st, d, ag))

    print("| 규칙 | alert 일치 | 단계 2 묶음 | 2→1→0 | 2→1 | 2→0 | 2→F | 2→이미 틀었음 | 2→반대 | 기타 | 끝↔반대 뒤집힘 (16:52:31~53:44 구간) | 같은 방향 단계 변화 |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for name, seq, st, d, ag in rows:
        print(f"| {name} | {100.0 * ag[0] / max(1, ag[1]):.1f}% ({ag[0]}/{ag[1]}) | {d['runs']} | {d['full']} | {d['to1']} | "
              f"{d['to0']} | {d['toF']} | {d['toT']} | {d['toOpp']} | {d['toNone']} | "
              f"{fmt_flips(st, loop)} | {level_changes(seq)} |")
    print()
    print("| 장면 | 원인(T144) | 이전 | T146 |")
    print("|---|---|---|---|")
    for sid, ft, cause in SCENES:
        ks = []
        for name, seq, st, d, ag in rows:
            r = state_at(seq, ft + 200)  # 프레임 저장 줄은 촬영 뒤 약 0.15~0.3초
            ks.append("-" if r is None else kind(r[1], r[2], r[3], r[4]))
        print(f"| {sid} | {cause} | {ks[0]} | {ks[1]} |")
    if args.paths:
        for name, seq, st, d, ag in rows:
            print(f"\n## {name} 단계 2 경로")
            for t, k, path, nxt in d["paths"]:
                print(t, k, "→".join(path) or "-", "→", nxt)


if __name__ == "__main__":
    main()
