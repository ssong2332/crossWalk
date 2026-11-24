"""T202 재생: '차도입니다'(노면 road)를 지금 규칙(T191) + 새 규칙 후보로 다시 돌린다 (코드 수정 전 분석).

지금 규칙 (feedback_service.dart T191): surf.ev road -> 3초 보류. 보류 중 어느 프레임이든 앱 판정
  (alert.cls = detectedClass)이 approach·front·left·right면 취소, 아니면 3초 뒤 말함.
새 규칙 후보 (T202): 같은 보류 3초 동안 **분류기 원값** cls.best가 front·left·right인 프레임이 있으면 취소.
  (11/18 18:39:57.0: cls.best front 연속인데 cw 게이트가 alert.cls를 none으로 내려 T191이 못 막음)
  변형 END: 보류 끝 순간의 cls.best만 본다 (덜 공격적).
옛 빌드 기록도 지금 규칙으로 다시 시뮬레이션한다 (옛 빌드의 실제 발화와 다를 수 있음 — 기록의 alert.cls는 그 빌드 게이트 기준).

실행 (워크트리 루트): PYTHONIOENCODING=utf-8 python train/t202/t202_replay.py
출력: train/t202/replay.csv + 콘솔 요약
"""
import csv, datetime as dt, json, os, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LOGS = Path(os.environ.get("T202_LOGS", "C:/vibecoding/crossWalk/logs"))
FILES = {"11/11": "log_20261111_175418.jsonl", "11/12": "crosswalk log 2bccfa2.txt",
         "11/18": "log_20261118_183224.jsonl", "11/22": "log_20261122_185021.jsonl"}
ON = {"front", "left", "right"}
HOLD = 3000
K = dt.timezone(dt.timedelta(hours=9))


def clk(t):
    return dt.datetime.fromtimestamp(t / 1000, K).strftime("%H:%M:%S.%f")[:-5]


def episodes(R):
    """지금 규칙으로 보류 구간을 만든다: road_wait 시각 t, 끝 t+3s (보류 중 road는 road_dup)."""
    eps, busy_until = [], -1
    for r in R:
        if r["ev"] == "surf.ev" and "road" in r.get("names", []) and r["t"] > busy_until:
            eps.append(r["t"]); busy_until = r["t"] + HOLD
    return eps


def judge(R, t):
    """보류 [t, t+3s] 안의 alert.cls / cls.best -> (T191 취소?, 새 규칙 취소?, END 변형 취소?, 근거)."""
    win = [r for r in R if t <= r["t"] <= t + HOLD]
    acls = [r["cls"] for r in win if r["ev"] == "alert"]
    best = [r["best"] for r in win if r["ev"] == "cls"]
    t191 = any(c == "approach" or c in ON for c in acls)
    new = t191 or any(b in ON for b in best)
    end = t191 or (bool(best) and best[-1] in ON)
    gate = sum(1 for r in win if r["ev"] == "cwgate" and r.get("v") == "drop")
    return t191, new, end, dict(alert=",".join(sorted(set(acls))), best=",".join(sorted(set(best))),
                                 best_on=sum(b in ON for b in best), n=len(best), cwdrop=gate)


def actual(R, t):
    """그 빌드에서 실제로 '차도입니다'를 말했는가 (t ~ t+3.5s 사이 say 차도)."""
    return any(r["ev"] == "say" and "차도" in r.get("text", "") and t - 100 <= r["t"] <= t + HOLD + 500 for r in R)


if __name__ == "__main__":
    # 자체 검사: 합성 기록
    S = [{"ev": "surf.ev", "names": ["road"], "t": 0}, {"ev": "alert", "cls": "none", "t": 100},
         {"ev": "cls", "best": "front", "t": 100}, {"ev": "cls", "best": "none", "t": 2500},
         {"ev": "surf.ev", "names": ["road"], "t": 2000},
         {"ev": "surf.ev", "names": ["road"], "t": 3500}, {"ev": "alert", "cls": "approach", "t": 3600},
         {"ev": "cls", "best": "approach", "t": 3600}]
    assert episodes(S) == [0, 3500]
    assert judge(S, 0)[:3] == (False, True, False) and judge(S, 3500)[:3] == (True, True, True)
    out = []
    for day, f in FILES.items():
        R = [json.loads(l) for l in open(LOGS / f, encoding="utf-8") if l.strip()]
        build = next((r.get("build", "")[:7] for r in R if r["ev"] == "log.start"), "")
        for t in episodes(R):
            t191, new, end, why = judge(R, t)
            out.append(dict(day=day, build=build, time=clk(t), said_actual=int(actual(R, t)),
                            t191_said=int(not t191), new_said=int(not new), end_said=int(not end), **why))
    with open(HERE / "replay.csv", "w", newline="", encoding="utf-8-sig") as fp:
        w = csv.DictWriter(fp, fieldnames=list(out[0])); w.writeheader(); w.writerows(out)
    print("| 날 | 빌드 | 보류 구간 | 그 빌드 실제 발화 | 지금 규칙(T191) 발화 | 새 규칙 발화 | END 변형 발화 |")
    for day in FILES:
        o = [x for x in out if x["day"] == day]
        print(f"| {day} | {o[0]['build'] if o else ''} | {len(o)} | {sum(x['said_actual'] for x in o)} | "
              f"{sum(x['t191_said'] for x in o)} | {sum(x['new_said'] for x in o)} | {sum(x['end_said'] for x in o)} |")
    print("\n새 규칙이 더 막는 순간 (T191은 말함, 새 규칙은 취소):")
    for x in out:
        if x["t191_said"] and not x["new_said"]:
            print(x)
