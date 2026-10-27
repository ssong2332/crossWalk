"""T143: 끝 규칙 '이미 틀었음' 히스테리시스 효과를 실기기 기록으로 재현한다(추정).

기록의 angle/pos 평활값과 alert(위 여부)를 시간 순서대로 넣어 DirectionResolver
판정을 규칙별로 다시 계산한다. 앱의 실제 호출 시점(분류·각도·위치 경로)을
기록 줄로 근사하므로 수치는 추정이다.

사용: PYTHONIOENCODING=utf-8 python train/t143_edge_turned_replay.py logs/a.jsonl [logs/b.jsonl ...]
"""
import json
import sys

DEV, REC, EDGE_POS, STEER = 12.0, 9.0, 1.0, 20.0
ON = {"front", "left", "right"}

RULES = {
    # 10/26 밤 빌드: 상한 없음(T100 그대로)
    "T100(상한 없음)": dict(cap=None, cap_in=None, low_keep=None),
    # T137: 상한 25, 떨림 방지 없음(10/27 빌드)
    "T137(상한 25)": dict(cap=25.0, cap_in=None, low_keep=None),
    # T143 ①: 상한 나갈 때 >25, 들어올 때 <=21
    "T143(25/21)": dict(cap=25.0, cap_in=21.0, low_keep=None),
    # T143 ① + 하한 들어갈 때 >=12, 유지 >=9
    "T143(25/21+12/9)": dict(cap=25.0, cap_in=21.0, low_keep=9.0),
}


def steer(p, a, prev, prev_edge, r):
    if p is None:
        return None
    if p <= -EDGE_POS:
        cw, over, out = -1.0, "right", STEER
    elif p >= EDGE_POS:
        cw, over, out = 1.0, "left", -STEER
    else:
        return None
    m = None if a is None else cw * a  # 중앙 쪽으로 튼 크기(+)
    cap = r["cap"]
    if cap is not None and r["cap_in"] is not None and prev == over:
        cap = r["cap_in"]
    if m is not None and cap is not None and m > cap:
        return None
    low = DEV
    if r["low_keep"] is not None and prev == "front" and prev_edge:
        low = r["low_keep"]
    return 0.0 if (m is not None and m >= low) else out


def resolve(a, p, prev, prev_edge, r):
    s = steer(p, a, prev, prev_edge, r)
    if s is not None:
        return ("front" if s == 0 else ("left" if s > 0 else "right")), True
    if a is None:
        return prev if prev in ON else "front", False
    if prev == "left" and a >= REC:
        return "left", False
    if prev == "right" and a <= -REC:
        return "right", False
    if a >= DEV:
        return "left", False
    if a <= -DEV:
        return "right", False
    return "front", False


def kind(label, edge):
    if label == "front" and edge:
        return "turned"  # 이미 틀었음
    if label in ("left", "right") and edge:
        return "steer"  # 끝 규칙: 중앙 쪽으로
    if label in ("left", "right"):
        return "dev"  # 각도 이탈
    return label


def run(path, r):
    a = p = None
    on = False
    label, edge = "front", False
    t_prev = None
    still = False
    out = dict(turned_s=0.0, turned_still_s=0.0, entries=0, flip25=0, flip12=0,
               flip25_fast=0, flip12_fast=0, steer_s=0.0, turned_calls_gap=0)
    last_change = {}
    seq = []
    last_vib_t = None
    for line in open(path, encoding="utf-8"):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        ev, t = e.get("ev"), e.get("t")
        if t is None:
            continue
        if t_prev is not None and on:
            dt = (t - t_prev) / 1000.0
            k = kind(label, edge)
            if k == "turned":
                out["turned_s"] += dt
                if still:
                    out["turned_still_s"] += dt
            elif k == "steer":
                out["steer_s"] += dt
        t_prev = t
        if ev == "still" and "on" in e:
            still = bool(e["on"])
            continue
        if ev == "angle":
            a = e.get("smooth")
        elif ev == "pos":
            p = e.get("smooth")
        elif ev == "alert":
            on = e.get("cls") in ON
            logged = (e.get("cls"), bool(e.get("edge")))
        elif ev == "state" and e.get("to") not in ON:
            on = False
        else:
            continue
        if not on:
            label, edge = "none", False
            continue
        new_label, new_edge = resolve(a, p, label, edge, r)
        if ev == "alert":
            out["n_alert"] = out.get("n_alert", 0) + 1
            if (new_label, new_edge) == logged:
                out["agree"] = out.get("agree", 0) + 1
        k0, k1 = kind(label, edge), kind(new_label, new_edge)
        if k1 == "turned" and ev == "alert":
            # 경고 호출 때만 진동을 검사하던 방식으로 lvl0(600ms) 진동 수 추정
            if last_vib_t is None or t - last_vib_t >= 600:
                out["turned_calls_gap"] += 1
                last_vib_t = t
        if k1 != "turned":
            last_vib_t = None
        if k0 != k1:
            pair = frozenset((k0, k1))
            if k1 == "turned":
                out["entries"] += 1
            at_edge_pos = p is not None and abs(p) >= EDGE_POS
            if pair == frozenset(("turned", "dev")) and at_edge_pos:
                out["flip25"] += 1
                if t - last_change.get(pair, -10**9) < 3000:
                    out["flip25_fast"] += 1
                last_change[pair] = t
            if pair == frozenset(("turned", "steer")) and at_edge_pos:
                out["flip12"] += 1
                if t - last_change.get(pair, -10**9) < 3000:
                    out["flip12_fast"] += 1
                last_change[pair] = t
            seq.append((t, k0, k1, a, p))
        label, edge = new_label, new_edge
    out["timer_vibs"] = int(out["turned_s"] / 0.6)
    return out, seq


def main():
    for path in sys.argv[1:]:
        print(f"## {path}")
        print("| 규칙 | alert 일치 | 이미 틀었음 시간 s (서있음) | 진입 | 25 경계 뒤집힘 (3초 안) | 12 경계 뒤집힘 (3초 안) | 끝 유도 시간 s | 추가 진동 추정: 타이머 600ms / 경고 호출 기준 |")
        print("|---|---|---|---|---|---|---|---|")
        for name, r in RULES.items():
            o, _ = run(path, r)
            agree = 100.0 * o.get("agree", 0) / max(1, o.get("n_alert", 0))
            print(f"| {name} | {agree:.1f}% | {o['turned_s']:.1f} ({o['turned_still_s']:.1f}) | {o['entries']} | "
                  f"{o['flip25']} ({o['flip25_fast']}) | {o['flip12']} ({o['flip12_fast']}) | "
                  f"{o['steer_s']:.1f} | {o['timer_vibs']} / {o['turned_calls_gap']} |")
        print()


if __name__ == "__main__":
    main()
