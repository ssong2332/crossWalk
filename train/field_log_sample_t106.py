"""T106: 분석 스크립트(`field_log_t106.py --selftest`)용 합성 기록 — 답을 미리 아는 2분짜리 세션.

시나리오(기록 시작 기준 초):
  1~60   인도(none): 10.5 선형 올라섬 → 11.5 linearOn·진동 / 20.5 왼쪽으로 비킴 → 21.5 linearRight·P2
         35.5 점형 → 36.5 dotBlock·P1 / 44.5 점형 1장(반응 없음) / 50.5 차도 → 51.5·54.5·57.5 road·P0·진동
  60~75  approach / 75 front, 진입 P1(76.02 이탈 P0에 끊김) / 75.5 각도 14° → 76 left
  76~81  left(음성·진동 76.02, 79.0x) → 81 front 복귀
  84~84.4 right 0.4초(깜빡임, 왼쪽으로 안내가 직진하세요에 끊김)
  90~96  left: 90.02 한 번뿐 → 이탈 중 침묵 5.97초
  100    crossed P1 / 100.62 P2 버림(busy_p1) / 102.52 P2 버림(min_gap)
  105~110 nocall / 112~114.5 분류기 공백 / 115~118 앱 내려감(공백 아님)
"""
import json
import os
from datetime import datetime, timedelta, timezone

KST = timezone(timedelta(hours=9))
T0 = datetime(2026, 10, 2, 10, 0, 0, tzinfo=KST).timestamp()
REC_LEAD = 5.0  # 화면 녹화가 기록보다 5초 먼저 시작

EXPECT = {
    "episodes": 3, "silent": 1, "flicker": 1, "interrupted": 2, "dropped": 2,
    "dropped_reasons": {"busy_p1": 1, "min_gap": 1}, "stalls": 1, "no_guidance_s": 5.4,
    "surface_events": {"linearOn": 1, "linearRight": 1, "dotBlock": 1, "road": 3},
    "reactions": {"반응": 3, "반응 없음": 1, "상태 때문에 침묵(정상)": 1},
    "evidence_n": 1, "evidence_p50": 0.5, "on_block_p50": 10.0,
    "vib": {"line_on": 1, "road": 3, "left": 3, "right": 1, "recover": 3},
    "repeats": 4, "occ_under_limit": True,
}

STATES = [(0.6, None, "loading"), (1.0, "loading", "none"), (60.0, "none", "approach"),
          (75.0, "approach", "front"), (76.0, "front", "left"), (81.0, "left", "front"),
          (84.0, "front", "right"), (84.4, "right", "front"), (90.0, "front", "left"),
          (96.0, "left", "front"), (100.0, "front", "crossed"), (105.0, "crossed", "nocall"),
          (110.0, "nocall", "none")]
END = 120.0
PAUSE = (115.0, 118.0)

# (요청 시각, P, 문장, act, why, 재생 길이 초 | None)
SPEECH = [
    (21.52, 2, "점자블록 오른쪽", "speakNow", "ok", 1.10),
    (36.52, 1, "멈춤 블록입니다", "speakNow", "ok", 1.20),
    (51.52, 0, "차도입니다", "speakNow", "p0", 0.80),
    (54.52, 0, "차도입니다", "speakNow", "p0", 0.80),
    (57.52, 0, "차도입니다", "speakNow", "p0", 0.80),
    (75.02, 1, "횡단보도에 진입했습니다.", "speakNow", "ok", 1.01),
    (76.02, 0, "오른쪽으로 이동하세요", "speakNow", "interrupt_p1", 1.40),
    (79.05, 0, "오른쪽으로 이동하세요", "speakNow", "p0", 1.40),
    (81.02, 0, "직진하세요", "speakNow", "p0", 0.80),
    (84.02, 0, "왼쪽으로 이동하세요", "speakNow", "p0", 0.40),
    (84.42, 0, "직진하세요", "speakNow", "interrupt_p0", 0.80),
    (90.02, 0, "오른쪽으로 이동하세요", "speakNow", "p0", 1.40),
    (96.02, 0, "직진하세요", "speakNow", "p0", 0.80),
    (100.02, 1, "횡단보도를 건넜습니다.", "speakNow", "ok", 1.50),
    (100.62, 2, "점자블록을 벗어났습니다", "drop", "busy_p1", None),
    (102.52, 2, "멈춤 블록입니다", "drop", "min_gap", None),
]
VIBS = [(11.52, "line_on", [0, 125]), (51.53, "road", [0, 125, 125, 125, 125, 125]),
        (54.53, "road", [0, 125, 125, 125, 125, 125]), (57.53, "road", [0, 125, 125, 125, 125, 125]),
        (76.03, "left", [0, 125, 125, 125]), (79.02, "left", [0, 125, 125, 125]),
        (81.03, "recover", [0, 125]), (84.03, "right", [0, 500]), (84.43, "recover", [0, 125]),
        (90.03, "left", [0, 125, 125, 125]), (96.03, "recover", [0, 125])]
SURF_EV = [(11.5, ["linearOn"]), (21.5, ["linearRight"]), (36.5, ["dotBlock"]),
           (51.5, ["road"]), (54.5, ["road"]), (57.5, ["road"])]


def _state(t):
    cur = None
    for at, _, to in STATES:
        if at <= t:
            cur = to
    return cur


def _surface(t):
    F, L, R = [0.9, 0, 0, 0], [0.9, 0, 0, 0], [0.9, 0, 0, 0]
    if 10.5 <= t < 20:
        F = [0.7, 0, 0.2, 0]
    elif 20.5 <= t < 25:
        R = [0.7, 0, 0.2, 0]
    elif 35.5 <= t < 40:
        F = [0.7, 0, 0, 0.2]
    elif abs(t - 44.5) < 0.01:
        F = [0.8, 0, 0, 0.1]
    elif 50.5 <= t < 60:
        F = [0.1, 0.8, 0, 0]
    elif abs(t - 77.5) < 0.01:
        F = [0.2, 0.7, 0, 0]
    elif t >= 60:
        F = [0.6, 0.3, 0, 0]
    return F, L, R


def write_sample(out):
    rows = []

    def add(_rel, _name, /, **d):
        rows.append({"t": int(round((T0 + _rel) * 1000)), "ms": 1000 + int(round(_rel * 1000)),
                     "ev": _name, **d})

    add(0.0, "log.start", file="log_20261002_100000.jsonl", build="selftest")
    add(0.1, "model", name="cls", ok=True, dur=420)
    add(0.2, "model", name="angle", ok=True, dur=380)
    add(0.3, "model", name="pos", ok=True, dur=370)
    add(0.5, "camera", ok=True, sensor=90, preview="Size(720.0, 480.0)")
    add(2.0, "set", key="surface", value=True)
    add(2.1, "model", name="surface", ok=True, dur=510)
    for at, frm, to in STATES:
        add(at, "state", **{"from": frm, "to": to, "edge": False, "conf": 0.8})
    add(PAUSE[0], "app.life", state="inactive")
    add(PAUSE[0] + 0.1, "app.life", state="paused")
    add(PAUSE[1], "app.life", state="resumed")

    t = 1.0
    while t <= END + 1e-9:
        if not (112.0 < t < 114.5) and not (114.5 < t < 118.5):
            st = _state(t)
            best = "front" if st in ("hold",) else ("none" if st in ("nocall", "loading") else st)
            nocall = st == "nocall"
            probs = [0.04] * 6
            probs[["none", "approach", "front", "left", "right", "crossed"].index(best)] = 0.8
            add(t, "cls", best=best, conf=0.35 if nocall else 0.8, ok=not nocall, probs=probs,
                avg=probs, dur=85 + int(t * 10) % 6)
        t = round(t + 0.5, 3)

    t = 60.5
    while t < 105:
        st = _state(t)
        smooth = 14.0 if 75.5 <= t < 81 else 3.0
        add(t, "angle", raw=smooth, smooth=smooth, label=st, dur=58)
        if st in ("front", "left", "right"):
            add(t + 0.4, "pos", raw=0.0, smooth=0.0, label=st, dur=50)
        t += 1.0

    t = 2.5
    while t < END:
        if not (PAUSE[0] < t < PAUSE[1]):
            F, L, R = _surface(t)
            add(t, "surf", ok=True, L=L, F=F, R=R, st=_state(t), dur=97)
        t += 1.0
    for at, evs in SURF_EV:
        add(at + 0.001, "surf.ev", names=evs, st=_state(at))

    for at, p, text, act, why, dur in SPEECH:
        add(at, "say", text=text, p=p, act=act, why=why)
        if dur is not None:
            add(at + dur, "say.end", text=text, p=p, res="done", dur=int(round(dur * 1000)))
    for at, kind, pat in VIBS:
        add(at, "vib", kind=kind, ok=True, mode="pattern", pat=pat)

    rows.sort(key=lambda r: (r["ms"], r["t"]))
    log_path = os.path.join(out, "log_20261002_100000.jsonl")
    with open(log_path, "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    checklist = {"results": {
        "A": {"status": "pass", "videoTime": "00:16", "note": ""},
        "B": {"status": "pass", "videoTime": "00:26", "note": ""},
        "E": {"status": "fail", "videoTime": "00:41", "note": "못 들음"},
        "F": {"status": "pass", "videoTime": "00:55", "note": ""},
        "G": {"status": "pass", "videoTime": "01:22", "note": ""},
    }, "meta": {}, "notes": []}
    ck_path = os.path.join(out, "checklist_sample.json")
    json.dump(checklist, open(ck_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    return log_path, ck_path, T0 - REC_LEAD
