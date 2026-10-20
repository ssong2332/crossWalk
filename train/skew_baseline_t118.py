"""T118 기울어진 횡단보도 — '진입 직후 기울기 보정' 규칙을 실기기 기록으로 다시 계산한다(앱 미변경).

판정 기준표(2026-10-17 대화):
  횡단 1회  상태가 위(front/left/right)로 들어온 때 ~ crossed/none/approach. hold는 같은 횡단으로 본다.
  기울기    들어선 뒤 처음 BASE_S초 동안 angle.smooth 평균(3개 미만이면 보정 없음).
  보정      BASE_S초가 지난 뒤부터 angle - 기울기. 처음 BASE_S초는 지금과 같다.
  판정      direction_resolver.dart 그대로 — 끝 |pos|>=1 먼저, 이탈 12도, 회복 9도(같은 방향 유지).
  비교      같은 기록을 지금/보정 규칙으로 다시 계산해 이탈(left/right 진입) 횟수와 시각을 낸다.

사용: python train/skew_baseline_t118.py logs/a.jsonl [logs/b.jsonl ...]
"""
import json, sys
from pathlib import Path

DEV, REC, EDGE, BASE_S = 12.0, 9.0, 1.0, 2.0
ON = ("front", "left", "right")


def resolve(a, pos, prev):
    if pos is not None and pos <= -EDGE: return "front" if a is not None and a <= -DEV else "left"
    if pos is not None and pos >= EDGE: return "front" if a is not None and a >= DEV else "right"
    if a is None: return "front"
    if prev == "left" and a >= REC: return "left"
    if prev == "right" and a <= -REC: return "right"
    return "left" if a >= DEV else ("right" if a <= -DEV else "front")


def run(path):
    L = [json.loads(l) for l in open(path, encoding="utf-8")]
    t0 = L[0]["t"]
    state, pos, crossing = None, None, None
    out = []
    for i, e in enumerate(L):
        ev = e["ev"]
        if ev == "state":
            to = e["to"]
            if to in ON and crossing is None:
                crossing = {"start": e["t"], "line": i + 1, "base": [], "skew": None,
                            "prev": {"orig": to, "corr": to}, "alerts": {"orig": [], "corr": []}}
            elif to not in ON and to != "hold" and crossing is not None:
                crossing["end"] = e["t"]; out.append(crossing); crossing = None
            state = to
        elif ev == "pos":
            pos = e.get("smooth")
        elif ev == "angle" and crossing is not None and state in ON:
            a = e.get("smooth")
            dt = (e["t"] - crossing["start"]) / 1000
            if a is not None and dt <= BASE_S:
                crossing["base"].append(a)
            elif crossing["skew"] is None and len(crossing["base"]) >= 3:
                crossing["skew"] = sum(crossing["base"]) / len(crossing["base"])
            for k in ("orig", "corr"):
                aa = a
                if k == "corr" and a is not None and crossing["skew"] is not None and dt > BASE_S:
                    aa = a - crossing["skew"]
                st = resolve(aa, pos, crossing["prev"][k])
                if st in ("left", "right") and crossing["prev"][k] != st:
                    edge = pos is not None and abs(pos) >= EDGE
                    crossing["alerts"][k].append({"s": round((e["t"] - t0) / 1000, 1), "line": i + 1,
                                                  "to": st, "angle": None if aa is None else round(aa, 1),
                                                  "pos": None if pos is None else round(pos, 2), "edge": edge})
                crossing["prev"][k] = st
    if crossing is not None:
        crossing["end"] = L[-1]["t"]; out.append(crossing)
    actual = sum(1 for e in L if e["ev"] == "state" and e["to"] in ("left", "right") and e["from"] != e["to"])
    return L, t0, out, actual


def main(paths):
    for p in paths:
        L, t0, cr, actual = run(p)
        o = sum(len(c["alerts"]["orig"]) for c in cr); c_ = sum(len(c["alerts"]["corr"]) for c in cr)
        print(f"\n=== {Path(p).name}: 횡단 {len(cr)}회 · 이탈 진입 실제 기록 {actual} / 지금 규칙 재계산 {o} / 보정 규칙 {c_}")
        for c in cr:
            s = round((c["start"] - t0) / 1000, 1); d = round((c["end"] - c["start"]) / 1000, 1)
            skew = None if c["skew"] is None else round(c["skew"], 1)
            ko = [(a["s"], a["to"], "끝" if a["edge"] else "") for a in c["alerts"]["orig"]]
            kc = [(a["s"], a["to"], "끝" if a["edge"] else "") for a in c["alerts"]["corr"]]
            gone = [a for a in c["alerts"]["orig"] if not any(abs(a["s"] - b["s"]) < 0.6 and a["to"] == b["to"] for b in c["alerts"]["corr"])]
            new = [b for b in c["alerts"]["corr"] if not any(abs(a["s"] - b["s"]) < 0.6 and a["to"] == b["to"] for a in c["alerts"]["orig"])]
            print(f"  횡단 L{c['line']} {s}초부터 {d}초 · 기울기 {skew}도 · 지금 {len(ko)} → 보정 {len(kc)}")
            for a in gone: print(f"     사라짐 {a['s']}초 L{a['line']} {a['to']} 각도 {a['angle']} 위치 {a['pos']}{' 끝' if a['edge'] else ''}")
            for b in new: print(f"     새로 생김 {b['s']}초 L{b['line']} {b['to']} 각도 {b['angle']} 위치 {b['pos']}{' 끝' if b['edge'] else ''}")


if __name__ == "__main__":
    main(sys.argv[1:])
