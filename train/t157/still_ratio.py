"""T157 A: '위' 구간마다 정지(still) 비율을 기록에서 다시 잰다.

위 구간 = state가 위(front/left/right)가 아닌 곳(hold 제외)에서 위로 들어온 시각부터
crossed 상태 또는 hold.end(해제)까지. 그사이 위 <-> hold는 이어진 것으로 본다
(CrossingHold._onSince와 같은 정의). 정지 = still 줄(on) 기준 시간 비율.
사용: PYTHONIOENCODING=utf-8 python train/t157/still_ratio.py LOG [LOG ...]
"""
import json
import sys
from datetime import datetime

ON = {"front", "left", "right"}


def hms(t):
    return datetime.fromtimestamp(t / 1000).strftime("%H:%M:%S.%f")[:-4]


def episodes(path):
    still, still_since = False, None
    segs = []  # (start, end) still 구간
    eps = []
    cur = None
    said_next = None
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        ev, t = e.get("ev"), e.get("t")
        if t is None:
            continue
        if ev == "still" and "on" in e:
            on = bool(e["on"])
            if on and not still:
                still_since = t
            if not on and still and still_since is not None:
                segs.append((still_since, t))
            still = on
        elif ev == "state":
            fr, to = e.get("from"), e.get("to")
            if to in ON and fr not in ON and fr != "hold":
                cur = dict(start=t, line=n, end=None, how=None, said=None)
            elif cur and to == "crossed":
                cur.update(end=t, how="crossed", endline=n)
                eps.append(cur)
                cur = None
            elif cur and to not in ON and to != "hold" and fr in ON:
                cur.update(end=t, how="to_" + to, endline=n)
                eps.append(cur)
                cur = None
        elif ev == "hold.end" and cur:
            cur.update(end=t, how="hold." + str(e.get("why")),
                       said=e.get("said"), endline=n, dur=e.get("dur"))
            eps.append(cur)
            cur = None
    if still and still_since is not None:
        segs.append((still_since, 1 << 62))

    def ratio(a, b):
        s = sum(max(0, min(b, y) - max(a, x)) for x, y in segs)
        return s / max(1, b - a)
    for ep in eps:
        ep["ratio"] = ratio(ep["start"], ep["end"])
        ep["len"] = (ep["end"] - ep["start"]) / 1000
    return eps


def phase_said(path):
    """'건넜습니다' 요청(say) 시각 목록."""
    out = []
    for line in open(path, encoding="utf-8"):
        if '"건넜습니다' not in line and "건넜습니다" not in line:
            continue
        e = json.loads(line)
        if e.get("ev") == "alert" and e.get("phase") and "건넜" in e["phase"]:
            out.append(e["t"])
    return out


if __name__ == "__main__":
    for path in sys.argv[1:]:
        said = phase_said(path)
        print(f"## {path}")
        print("| 시작 | 줄 | 끝 | 길이(초) | 정지 비율 | 걸은 시간(초) | '건넜습니다'(기록) | 발밑 해제 새 규칙(걸은 시간 >= 6초) |")
        print("|---|---|---|---|---|---|---|---|")
        for ep in episodes(path):
            s = any(ep["end"] - 100 <= x <= ep["end"] + 6000 for x in said)
            if ep["how"].startswith("to_") and not s:
                continue
            walk = ep["len"] * (1 - ep["ratio"])
            new = "-"
            if ep["how"] == "hold.ground":
                new = ("말함" if walk >= 6 else "안 말함") if ep["len"] >= 6 else "안 말함(T140 6초 미만)"
            print(f"| {hms(ep['start'])} | L{ep['line']} | {ep['how']} L{ep['endline']} | "
                  f"{ep['len']:.1f} | {ep['ratio']:.2f} | {walk:.1f} | {'말함' if s else '-'} | {new} |")
