"""T157 A(진입) 재생: alert 줄의 none -> 위 전이마다 새 규칙이 진입 안내를 어떻게 할지 본다(추정).

새 규칙(feedback_service.dart decidePhaseMessage):
  - 직전 3초 안에 approach(alert cls)가 있었음 → 지금처럼 바로.
  - 아니고 그 순간 정지(still 줄 기준) → 미룸. 위에 있는 동안 정지가 풀리면 그때 말함,
    그 전에 위를 벗어나면(none/approach/crossed alert) 버림.
  - T149 9초 침묵(건넌 신호 뒤)은 여기서 따로 보지 않고, 기록의 alert phase로 진입이 실제로
    요청됐는지 함께 적는다.
사용: PYTHONIOENCODING=utf-8 python train/t157/entry_replay.py LOG [LOG ...]
"""
import json
import sys
from datetime import datetime

ON = {"front", "left", "right"}
ENTRY = "횡단보도 진입."


def hms(t):
    return datetime.fromtimestamp(t / 1000).strftime("%H:%M:%S.%f")[:-4]


def main(path):
    still = False
    last_cls = None
    last_approach = None
    waiting = None
    rows = []
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        ev, t = e.get("ev"), e.get("t")
        if ev == "still" and "on" in e:
            still = bool(e["on"])
            if waiting and not still:
                waiting["result"] = f"걸음 시작에 말함 (+{(t - waiting['t']) / 1000:.1f}초)"
                waiting = None
            continue
        if ev != "alert":
            continue
        cls = e.get("cls")
        if waiting and cls not in ON:
            waiting["result"] = f"버림 (+{(t - waiting['t']) / 1000:.1f}초 뒤 {cls})"
            waiting = None
        if last_cls == "none" and cls in ON:
            recent = last_approach is not None and t - last_approach <= 3000
            asked = e.get("phase") == ENTRY
            row = dict(t=t, line=n, cls=cls, recent=recent, still=still, asked=asked,
                       ago=None if last_approach is None else (t - last_approach) / 1000)
            if recent or not still:
                row["result"] = "바로 (지금과 같음)"
            else:
                row["result"] = "미룸 — 기록 끝까지 정지"
                waiting = row
            rows.append(row)
        if cls == "approach":
            last_approach = t
        last_cls = cls
    print(f"## {path}")
    print("| 시각 | 줄 | none→ | 직전 approach | 정지 | 기록에서 진입 요청 | 새 규칙 |")
    print("|---|---|---|---|---|---|---|")
    for r in rows:
        ago = "-" if r["ago"] is None else f"{r['ago']:.1f}초 전"
        print(f"| {hms(r['t'])} | L{r['line']} | {r['cls']} | {ago} | {'예' if r['still'] else '아니오'} | "
              f"{'예' if r['asked'] else '아니오(9초 침묵 등)'} | {r['result']} |")


if __name__ == "__main__":
    for p in sys.argv[1:]:
        main(p)
