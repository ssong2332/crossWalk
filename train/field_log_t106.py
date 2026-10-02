"""T106: 실기기 기록(개발용 기록 JSONL) + 화면 녹화 분석 — 접근성 경험(AX) 중심.

사용자(시각장애인)가 실제로 겪은 것을 시계열로 본다:
  받은 안내(음성·진동) / 못 받은 안내(버림·끊김·TTL) / 경고까지 걸린 시간 /
  이탈 중 침묵 / 상태 깜빡임 / 판정 없음 / 소리 점유 / 처리 공백 / 노면 변화에 대한 반응.
기록 형식은 docs/EventLog.md. 판정 기준은 아래 CRITERIA와 SCENE_EXPECT —
**초안(사용자 확인 전)**: 실제 기록에 적용하기 전에 표를 보여주고 확정받는다(전역 규칙 1).

실행:
  python train/field_log_t106.py logs/log_*.jsonl --out train/field_t106/<이름>
      [--video videos/Screen_Recording_*.mp4] [--checklist checklist.json]
      [--scene-video <영상>] [--tz 9] [--offset 초]
  python train/field_log_t106.py --selftest     # 합성 기록으로 지표·정렬 계산 검증
출력(--out): summary.json(지표 + 근거 파일:줄) / report.md / timeline_overview.png /
  window_*.png(장면·이탈 구간 확대) / frames_*.jpg(영상이 있을 때 사건 순간 프레임)
"""
import argparse
import bisect
import json
import math
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import numpy as np

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_STRINGS = os.path.join(REPO, "crosswalk_app", "lib", "localization",
                           "app_strings.dart")

# 판정 기준 (초안 — 전부 추정값, 사용자 확인 전)
CRITERIA = {
    # 이탈(left/right) 중 음성·진동이 이 시간보다 길게 없으면 '이탈 중 침묵'.
    # 근거: 같은 방향 재알림 3초(VibrationPolicy.repeatInterval) + 분류기 주기 약 0.5초 + 여유 0.5초.
    "danger_silence_s": 4.0,
    # 상태가 이 시간 안에 바로 이전 상태로 돌아오면 '깜빡임'.
    "flicker_s": 1.0,
    # 같은 프레임 안에서 안내 기록이 상태 기록보다 먼저 찍힐 수 있다(alert 뒤 state).
    "feedback_lead_s": 0.5,
    # 분류기 결과 간격이 이보다 길면 '처리 공백'(앱이 화면에서 내려간 구간은 뺀다).
    "stall_s": 1.0,
    # 같은 문장이 이 시간 안에 다시 재생되면 '반복'.
    "repeat_s": 10.0,
    # 소리 점유: 이 창 안 음성 재생 합계. 한도는 AudioPolicy 예산(P0 제외)과 같은 20초.
    "occupancy_window_s": 60.0,
    "occupancy_limit_s": 20.0,
    # 각도 근거 시작(T103 이탈 진입 12도).
    "angle_enter_deg": 12.0,
    # 노면 기준(docs/SurfaceGuidance.md): 차도 '많음' 50%, 선형·점형 '있음' 5%.
    "surface_many": 0.5,
    "surface_present": 0.05,
    # 비율이 기준을 넘은 뒤 이 시간 안의 노면 이벤트를 그 변화의 반응으로 본다.
    "surface_event_wait_s": 3.0,
    # 음성 X가 끝난 시각 근처(이 범위)에 다른 음성 요청이 있으면 X는 끊긴 것.
    "interrupt_tol_s": 0.05,
    # 체크리스트 '녹화 시각' 기준으로 볼 구간(초).
    "scene_window_s": (-5.0, 10.0),
    # 영상-기록 정렬: 음성 시작과 소리 시작의 허용 오차, 찾는 오프셋 범위.
    "align_tol_s": 0.3,
    "align_search_s": (-8.0, 8.0),
}

# 체크리스트 장면별로 '앱이 해야 할 일'(초안 — 사용자 확인 전).
#   need: 창 안에 있어야 하는 것 / forbid: 창 안에 없어야 하는 것
#   ("vib", kind) / ("surf", 이벤트) / ("say", 문구 키) / ("say_cat", 분류)
SCENE_EXPECT = {
    "A": {"title": "선형 블록에 올라서기",
          "need": [("vib", "line_on")], "forbid": [("say_cat", "surface")]},
    "B": {"title": "왼쪽으로 비켜서기",
          "need": [("surf", "linearRight"), ("say", "surfaceLinearRightMessage")]},
    "C": {"title": "오른쪽으로 비켜서기",
          "need": [("surf", "linearLeft"), ("say", "surfaceLinearLeftMessage")]},
    "D": {"title": "블록에서 멀리 벗어나기",
          "need": [("surf", "linearLost"), ("say", "surfaceLinearLostMessage")]},
    "E": {"title": "멈춤(점형) 블록",
          "need": [("surf", "dotBlock"), ("say", "surfaceDotBlockMessage")],
          "max": [("surf", "dotBlock", 1)]},
    "F": {"title": "인도에서 차도 비추기",
          "need": [("surf", "road"), ("say", "surfaceRoadMessage"), ("vib", "road")]},
    "G": {"title": "횡단보도 건너기", "forbid_on_crosswalk": [("say_cat", "surface")]},
    "H": {"title": "스위치 끄고 확인", "forbid_after_off": [("surf", "*")]},
}
QUADRANT = {
    (True, "pass"): "정상",
    (True, "fail"): "앱은 냈는데 사용자가 못 받음 — 인지 문제(소리·진동 세기, 타이밍, 소음)",
    (False, "pass"): "체감은 됐는데 기록에 없음 — 창 위치·녹화 시각 확인 필요",
    (False, "fail"): "앱이 안 냄 — 감지·판정 문제",
}

CLS_LABELS = ["none", "approach", "front", "left", "right", "crossed"]
SURF_KEYS = ["sidewalk", "road", "linear", "dot"]  # docs/EventLog.md: L/F/R 순서
SURF_KO = {"sidewalk": "인도", "road": "차도", "linear": "선형", "dot": "점형"}
DEVIATION = ("left", "right")
ON_CROSSWALK = ("front", "left", "right", "hold")
NO_GUIDANCE = ("nocall", "error", "loading")
SURFACE_ACTIVE = ("none", "crossed")
STATE_KO = {"right": "오른쪽 이탈", "left": "왼쪽 이탈", "front": "직진", "hold": "횡단 유지",
            "approach": "앞에 횡단보도", "crossed": "다 건넘", "none": "없음",
            "nocall": "판정 없음", "error": "오류", "loading": "준비 중"}
KNOWN_EVENTS = {"log.start", "log.on", "log.off", "log.share", "app.life", "set", "model",
                "camera", "error", "cls", "angle", "pos", "surf", "surf.ev", "state",
                "alert", "say", "say.end", "say.ttl", "vib"}


@dataclass
class Ev:
    t: float      # 폰 시계(초, epoch)
    ev: str
    d: dict
    src: str      # 파일:줄


@dataclass
class Session:
    name: str
    events: list
    start: float
    end: float


# ---------------------------------------------------------------- 읽기

def load_sessions(paths):
    """파일 하나 = 앱 실행 하나. 형식이 다른 줄은 버리지 않고 bad_lines로 보고한다."""
    sessions, bad, unknown = [], [], {}
    for p in sorted(paths):
        evs = []
        with open(p, encoding="utf-8") as f:
            for i, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                src = f"{os.path.basename(p)}:{i}"
                try:
                    m = json.loads(line)
                    t = float(m["t"]) / 1000.0
                    name = str(m["ev"])
                except (json.JSONDecodeError, KeyError, TypeError, ValueError):
                    bad.append({"src": src, "line": line[:200]})
                    continue
                if name not in KNOWN_EVENTS:
                    unknown[name] = unknown.get(name, 0) + 1
                evs.append(Ev(t, name, m, src))
        if not evs:
            continue
        evs.sort(key=lambda e: (e.d.get("ms", 0), e.t))
        sessions.append(Session(os.path.basename(p), evs, evs[0].t, evs[-1].t))
    sessions.sort(key=lambda s: s.start)
    return sessions, bad, unknown


def load_message_map(path=APP_STRINGS):
    """앱 문구 → 키(app_strings.dart에서 읽는다 — 문구가 바뀌어도 따라간다)."""
    out = {}
    if not os.path.exists(path):
        return out
    txt = open(path, encoding="utf-8").read()
    for key, s1, s2 in re.findall(r"(\w+Message\w*):\s*(?:'([^']*)'|\"([^\"]*)\")", txt):
        out.setdefault(s1 or s2, key)
    return out


def speech_category(text, msgmap):
    """(분류, 키). 분류: deviation / recovery / surface / phase / other."""
    key = msgmap.get(text)
    if key is None:
        return "other", None
    if key.startswith(("leftDeviation", "leftEdge", "rightDeviation", "rightEdge")):
        return "deviation", key
    if key in ("recoveredMessage", "edgeTurnedMessage"):
        return "recovery", key
    if key.startswith("surface"):
        return "surface", key
    if key in ("enteredCrosswalkMessage", "crossedCrosswalkMessage", "approachAheadMessage"):
        return "phase", key
    return "other", key


# ---------------------------------------------------------------- 시계열 만들기

def state_intervals(s):
    out, cur = [], None
    for e in s.events:
        if e.ev == "state":
            if cur:
                out.append({"a": cur[0], "b": e.t, "st": cur[1], "src": cur[2]})
            cur = (e.t, e.d.get("to"), e.src)
    if cur:
        out.append({"a": cur[0], "b": s.end, "st": cur[1], "src": cur[2]})
    return out


def state_at(intervals, t):
    starts = [iv["a"] for iv in intervals]
    i = bisect.bisect_right(starts, t) - 1
    return intervals[i]["st"] if i >= 0 else None


def speech_played(s, msgmap):
    out = []
    for e in s.events:
        if e.ev == "say.end":
            dur = (e.d.get("dur") or 0) / 1000.0
            cat, key = speech_category(e.d.get("text"), msgmap)
            out.append({"a": e.t - dur, "b": e.t, "text": e.d.get("text"), "p": e.d.get("p"),
                        "res": e.d.get("res"), "cat": cat, "key": key, "src": e.src})
    return out


def speech_requests(s):
    return [e for e in s.events if e.ev == "say"]


def pause_spans(s):
    """앱이 화면에서 내려가 있던 구간(app.life가 resumed가 아닌 동안)."""
    spans, down = [], None
    for e in s.events:
        if e.ev != "app.life":
            continue
        st = e.d.get("state")
        if st != "resumed" and down is None:
            down = e.t
        elif st == "resumed" and down is not None:
            spans.append((down, e.t))
            down = None
    if down is not None:
        spans.append((down, s.end))
    return spans


def stats(values):
    v = [x for x in values if x is not None]
    if not v:
        return {"n": 0}
    a = np.asarray(v, dtype=float)
    return {"n": len(v), "p50": round(float(np.percentile(a, 50)), 3),
            "p95": round(float(np.percentile(a, 95)), 3), "max": round(float(a.max()), 3)}


# ---------------------------------------------------------------- 지표 (접근성 경험)

def analyze_session(s, msgmap, C=CRITERIA):
    iv = state_intervals(s)
    played = speech_played(s, msgmap)
    reqs = speech_requests(s)
    vibs = [e for e in s.events if e.ev == "vib"]
    pauses = pause_spans(s)
    minutes = max((s.end - s.start) / 60.0, 1e-9)
    r = {"session": s.name, "duration_s": round(s.end - s.start, 1)}

    # 1. 받은 안내
    by_cat = {}
    for sp in played:
        by_cat[sp["cat"]] = by_cat.get(sp["cat"], 0) + 1
    vib_kind, vib_fail = {}, []
    for v in vibs:
        k = v.d.get("kind")
        if v.d.get("ok"):
            vib_kind[k] = vib_kind.get(k, 0) + 1
        else:
            vib_fail.append(v.src)
    r["received"] = {"speech_by_category": by_cat, "speech_total": len(played),
                     "speech_per_min": round(len(played) / minutes, 2),
                     "vibration_by_kind": vib_kind,
                     "vibration_per_min": round(sum(vib_kind.values()) / minutes, 2),
                     "vibration_not_delivered": {"n": len(vib_fail), "src": vib_fail[:10]}}

    # 2. 못 받은 안내 — 버림·대기 만료·끊김
    dropped = [e for e in reqs if e.d.get("act") == "drop"]
    drop_why = {}
    for e in dropped:
        drop_why[e.d.get("why")] = drop_why.get(e.d.get("why"), 0) + 1
    ttl = [e for e in s.events if e.ev == "say.ttl"]
    speak_req = [e for e in reqs if e.d.get("act") == "speakNow"]
    interrupted = []
    for sp in played:
        for q in speak_req:
            if sp["a"] + C["interrupt_tol_s"] < q.t <= sp["b"] + C["interrupt_tol_s"]:
                interrupted.append({"text": sp["text"], "by": q.d.get("text"),
                                    "heard_s": round(sp["b"] - sp["a"], 2), "src": sp["src"]})
                break
    r["missed"] = {
        "dropped": {"n": len(dropped), "by_reason": drop_why,
                    "items": [{"text": e.d.get("text"), "why": e.d.get("why"), "src": e.src}
                              for e in dropped[:20]]},
        "expired_in_queue": {"n": len(ttl), "src": [e.src for e in ttl[:10]]},
        "interrupted": {"n": len(interrupted), "items": interrupted[:20]},
    }

    # 3. 이탈 경고 — 반응 시간, 이탈 중 침묵, 받은 경로(음성/진동)
    dev_feedback = sorted(
        [(sp["a"], "say", sp["src"]) for sp in played if sp["cat"] == "deviation"] +
        [(v.t, "vib", v.src) for v in vibs if v.d.get("ok") and v.d.get("kind") in DEVIATION])
    angles = [(e.t, e.d.get("smooth")) for e in s.events if e.ev == "angle"]
    episodes = []
    for x in iv:
        if x["st"] not in DEVIATION:
            continue
        a, b = x["a"], x["b"]
        fb = [f for f in dev_feedback if a - C["feedback_lead_s"] <= f[0] <= b]
        times = [f[0] for f in fb]
        latency = round(max(0.0, times[0] - a), 3) if times else None
        prev, gaps = a, []
        for t in times:
            gaps.append(max(0.0, t - prev))
            prev = max(prev, t)
        gaps.append(max(0.0, b - prev))
        evidence = None  # 각도 근거가 기준을 넘은 시각(이탈 시작 전 5초 안, 마지막 상승 교차)
        prev_ang = None
        for (t, v) in angles:
            if t > a:
                break
            if t >= a - 5.0 and v is not None and abs(v) >= C["angle_enter_deg"] and \
                    (prev_ang is None or abs(prev_ang) < C["angle_enter_deg"]):
                evidence = t
            prev_ang = v
        kinds = {f[1] for f in fb}
        episodes.append({
            "state": x["st"], "start": a, "dur_s": round(b - a, 2), "src": x["src"],
            "first_feedback_s": latency,
            "evidence_to_state_s": round(a - evidence, 3) if evidence is not None else None,
            "max_silence_s": round(max(gaps), 2),
            "channels": "음성+진동" if kinds == {"say", "vib"} else
                        ("음성만" if kinds == {"say"} else ("진동만" if kinds else "없음")),
        })
    silent = [e for e in episodes if e["max_silence_s"] > C["danger_silence_s"]]
    no_fb = [e for e in episodes if e["first_feedback_s"] is None]
    r["deviation"] = {
        "episodes": len(episodes),
        "first_feedback_s": stats([e["first_feedback_s"] for e in episodes]),
        "evidence_to_state_s": stats([e["evidence_to_state_s"] for e in episodes]),
        "no_feedback": {"n": len(no_fb), "src": [e["src"] for e in no_fb[:10]]},
        "silent_episodes": {"n": len(silent), "limit_s": C["danger_silence_s"],
                            "items": [{"src": e["src"], "max_silence_s": e["max_silence_s"],
                                       "state": e["state"]} for e in silent[:10]]},
        "channels": {k: sum(1 for e in episodes if e["channels"] == k)
                     for k in ("음성+진동", "음성만", "진동만", "없음")},
        "items": episodes,
    }

    # 4. 상태 안정성 — 깜빡임, 바뀐 횟수, 판정 없음
    flicker = []
    for i in range(1, len(iv) - 1):
        s0, s1, s2 = iv[i - 1], iv[i], iv[i + 1]
        if s1["b"] - s1["a"] < C["flicker_s"] and s2["st"] == s0["st"] and s1["st"] != s0["st"]:
            flicker.append({"src": s1["src"], "path": f"{s0['st']}→{s1['st']}→{s2['st']}",
                            "dur_s": round(s1["b"] - s1["a"], 2)})
    noguide = [x for x in iv if x["st"] in NO_GUIDANCE]
    total_ng = sum(x["b"] - x["a"] for x in noguide)
    longest = max(noguide, key=lambda x: x["b"] - x["a"], default=None)
    time_by_state = {}
    for x in iv:
        time_by_state[x["st"]] = round(time_by_state.get(x["st"], 0.0) + (x["b"] - x["a"]), 1)
    r["stability"] = {
        "state_changes_per_min": round(max(len(iv) - 1, 0) / minutes, 2),
        "flicker": {"n": len(flicker), "limit_s": C["flicker_s"], "items": flicker[:20]},
        "no_guidance": {"total_s": round(total_ng, 1),
                        "share": round(total_ng / max(s.end - s.start, 1e-9), 3),
                        "longest_s": round(longest["b"] - longest["a"], 1) if longest else 0.0,
                        "longest_src": longest["src"] if longest else None},
        "time_by_state_s": time_by_state,
    }

    # 5. 소리 — 점유, 반복
    grid = np.arange(s.start, s.end + 0.1, 0.1)
    speaking = np.zeros(len(grid), dtype=bool)
    for sp in played:
        speaking[(grid >= sp["a"]) & (grid < sp["b"])] = True
    w = int(C["occupancy_window_s"] / 0.1)
    occ = np.convolve(speaking.astype(float), np.ones(w), mode="full")[:len(grid)] * 0.1
    over = float((occ > C["occupancy_limit_s"]).sum() * 0.1)
    repeats, last_by_text = {}, {}
    for sp in sorted(played, key=lambda z: z["a"]):
        lt = last_by_text.get(sp["text"])
        if lt is not None and sp["a"] - lt <= C["repeat_s"]:
            repeats[sp["text"]] = repeats.get(sp["text"], 0) + 1
        last_by_text[sp["text"]] = sp["a"]
    r["sound"] = {"speaking_share": round(float(speaking.mean()), 3),
                  "occupancy_max_s": round(float(occ.max()) if len(occ) else 0.0, 1),
                  "occupancy_over_limit_s": round(over, 1),
                  "occupancy_limit_s": C["occupancy_limit_s"],
                  "repeats_within_s": C["repeat_s"], "repeats": repeats}

    # 6. 처리 — 시간, 공백
    def durs(name):
        return [e.d.get("dur") for e in s.events if e.ev == name and e.d.get("dur") is not None]
    cls_t = [e.t for e in s.events if e.ev == "cls"]
    stalls = []
    for t0, t1 in zip(cls_t, cls_t[1:]):
        gap = t1 - t0
        if gap > C["stall_s"] and not any(p0 <= t1 and t0 <= p1 for p0, p1 in pauses):
            stalls.append({"at": t0, "gap_s": round(gap, 2)})
    r["processing"] = {
        "cls_ms": stats(durs("cls")), "angle_ms": stats(durs("angle")),
        "pos_ms": stats(durs("pos")), "surf_ms": stats(durs("surf")),
        "cls_interval_s": stats([b - a for a, b in zip(cls_t, cls_t[1:])]),
        "stalls": {"n": len(stalls), "limit_s": C["stall_s"],
                   "longest_s": max((x["gap_s"] for x in stalls), default=0.0)},
        "paused_s": round(sum(b - a for a, b in pauses), 1),
    }

    # 7. 노면 — 이벤트, 비율 변화에 대한 반응
    sev = [e for e in s.events if e.ev == "surf.ev"]
    ev_count = {}
    for e in sev:
        for name in e.d.get("names") or []:
            ev_count[name] = ev_count.get(name, 0) + 1
    surf = [e for e in s.events if e.ev == "surf" and e.d.get("ok")]
    rules = [("road", 1, C["surface_many"], "road"),
             ("dot", 3, C["surface_present"], "dotBlock"),
             ("linear", 2, C["surface_present"], "linearOn")]
    reactions = []
    for name, idx, thr, evname in rules:
        prev = None
        for e in surf:
            F = e.d.get("F") or [0, 0, 0, 0]
            v = F[idx] if len(F) > idx and F[idx] is not None else 0.0
            if prev is not None and prev < thr <= v:
                hit = next((x for x in sev if e.t <= x.t <= e.t + C["surface_event_wait_s"]
                            and evname in (x.d.get("names") or [])), None)
                st = e.d.get("st")
                reactions.append({
                    "kind": name, "at": e.t, "src": e.src, "state": st,
                    "event_s": round(hit.t - e.t, 3) if hit else None,
                    "result": "반응" if hit else ("상태 때문에 침묵(정상)" if st not in SURFACE_ACTIVE
                                                 else "반응 없음"),
                })
            prev = v
    on_block = []
    seq = [(e.t, n) for e in sev for n in (e.d.get("names") or [])]
    for i, (t, n) in enumerate(seq):
        if n == "linearOn":
            nxt = next(((t2, n2) for t2, n2 in seq[i + 1:]
                        if n2 in ("linearRight", "linearLeft", "linearLost")), None)
            if nxt:
                on_block.append(round(nxt[0] - t, 2))
    r["surface"] = {
        "events": ev_count,
        "events_per_min": round(sum(ev_count.values()) / minutes, 2),
        "reactions": {k: sum(1 for x in reactions if x["result"] == k)
                      for k in ("반응", "반응 없음", "상태 때문에 침묵(정상)")},
        "reaction_s": stats([x["event_s"] for x in reactions]),
        "no_reaction_items": [x for x in reactions if x["result"] == "반응 없음"][:20],
        "on_block_s": stats(on_block),
    }

    # 8. 기록 자체
    r["log"] = {"events": len(s.events),
                "model_fail": [{"name": e.d.get("name"), "err": e.d.get("err"), "src": e.src}
                               for e in s.events if e.ev == "model" and not e.d.get("ok")],
                "errors": [{"where": e.d.get("where"), "src": e.src}
                           for e in s.events if e.ev == "error"]}
    r["_series"] = {"iv": iv, "played": played, "reqs": reqs, "vibs": vibs,
                    "occ_t": grid, "occ": occ, "reactions": reactions}
    return r


# ---------------------------------------------------------------- 체크리스트 장면

def parse_mmss(s):
    m = re.match(r"^\s*(\d+):(\d{1,2})(?:\.(\d+))?\s*$", s or "")
    if not m:
        return None
    return int(m.group(1)) * 60 + int(m.group(2)) + (float("0." + m.group(3)) if m.group(3) else 0)


def judge_scenes(checklist, sessions, analyses, rec_start, offset, C=CRITERIA):
    """장면 창 안에서 앱이 낸 것을 SCENE_EXPECT로 판정하고, 사용자 체감과 교차한다."""
    out = []
    results = (checklist or {}).get("results", {})
    for sid, exp in SCENE_EXPECT.items():
        res = results.get(sid) or {}
        status = res.get("status") or ""
        vt = parse_mmss(res.get("videoTime"))
        row = {"scene": sid, "title": exp["title"], "user": status or "기록 없음",
               "videoTime": res.get("videoTime") or "", "note": res.get("note") or ""}
        if vt is None or rec_start is None:
            row.update(app=None, verdict="녹화 시각 없음 — 판정 못 함" if vt is None
                       else "영상 시작 시각 없음(--video) — 판정 못 함")
            out.append(row)
            continue
        t = rec_start + vt - offset
        lo, hi = t + C["scene_window_s"][0], t + C["scene_window_s"][1]
        sess = next((s for s in sessions if s.start - 5 <= t <= s.end + 5), None)
        if sess is None:
            row.update(app=None, verdict="그 시각의 기록 없음")
            out.append(row)
            continue
        an = analyses[sess.name]["_series"]
        win = [e for e in sess.events if lo <= e.t <= hi]
        said = [sp for sp in an["played"] if lo <= sp["a"] <= hi]
        found = {
            "vib": [e.d.get("kind") for e in win if e.ev == "vib" and e.d.get("ok")],
            "surf": [n for e in win if e.ev == "surf.ev" for n in (e.d.get("names") or [])],
            "say": [sp["key"] for sp in said],
            "say_cat": [sp["cat"] for sp in said],
        }
        ok, why = True, []
        for kind, val in exp.get("need", []):
            if val not in found[kind]:
                ok = False
                why.append(f"없음: {kind}={val}")
        for kind, val in exp.get("forbid", []):
            if val in found[kind]:
                ok = False
                why.append(f"있으면 안 됨: {kind}={val}")
        for kind, val, n in exp.get("max", []):
            if found[kind].count(val) > n:
                ok = False
                why.append(f"{n}회 초과: {kind}={val}")
        for kind, val in exp.get("forbid_on_crosswalk", []):
            bad = [sp for sp in said if sp[kind.replace("say_", "")] == val
                   and state_at(an["iv"], sp["a"]) in ON_CROSSWALK]
            if bad:
                ok = False
                why.append(f"횡단보도 위에서 {val} 음성 {len(bad)}회")
        for kind, val in exp.get("forbid_after_off", []):
            offs = [e.t for e in sess.events if e.ev == "set" and e.d.get("key") == "surface"
                    and e.d.get("value") is False and e.t <= hi]
            if not offs:
                why.append("창 안·앞에 노면 안내 끄기 기록 없음")
                ok = False
            else:
                after = [e for e in win if e.ev == "surf.ev" and e.t > offs[-1]]
                if after:
                    ok = False
                    why.append(f"끈 뒤에도 노면 이벤트 {len(after)}회")
        row.update(app=ok, found={k: v for k, v in found.items() if v}, why=why,
                   window=[round(lo, 2), round(hi, 2)], session=sess.name,
                   verdict=QUADRANT.get((ok, status), "사용자 기록이 '못 함'·없음 — 앱 동작만 참고"))
        out.append(row)
    return out


# ---------------------------------------------------------------- 영상 정렬

def recording_start(path, tz_hours):
    m = re.search(r"(\d{8})_(\d{6})", os.path.basename(path))
    if not m:
        return None
    dt = datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S")
    return dt.replace(tzinfo=timezone(timedelta(hours=tz_hours))).timestamp()


def ffmpeg_exe():
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:  # noqa: BLE001
        return None


def audio_onsets(path, rate=16000, hop_s=0.01):
    """영상 소리에서 소리가 시작된 시각들(초). 앞 0.25초가 조용하고 80ms 이상 이어진 소리만."""
    ff = ffmpeg_exe()
    if ff is None:
        return None, "ffmpeg 없음(imageio_ffmpeg)"
    raw = subprocess.run([ff, "-v", "error", "-i", path, "-vn", "-ac", "1", "-ar", str(rate),
                          "-f", "s16le", "-"], capture_output=True).stdout
    x = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    if len(x) < rate:
        return [], "소리 없음"
    hop = int(rate * hop_s)
    n = len(x) // hop
    rms = np.sqrt((x[:n * hop].reshape(n, hop) ** 2).mean(axis=1) + 1e-12)
    db = 20 * np.log10(rms)
    floor = float(np.percentile(db, 20))
    thr = max(floor + 12.0, -50.0)
    active = db > thr
    onsets, quiet, run = [], 0, 0
    for i, a in enumerate(active):
        if a:
            run += 1
            if run == 8 and quiet >= 25:  # 80ms 이어짐, 앞 250ms 조용
                onsets.append((i - 7) * hop_s)
        else:
            if run:
                quiet = 0
            run = 0
            quiet += 1
    return onsets, f"바닥 {floor:.1f}dB, 기준 {thr:.1f}dB"


def estimate_offset(starts_rel, onsets, C=CRITERIA):
    """기록상 음성 시작(영상 시작 기준 초)과 소리 시작을 가장 많이 맞추는 오프셋.
    영상 시각 = (기록 t - 녹화 시작) + offset."""
    if not starts_rel or not onsets:
        return None
    on = np.asarray(sorted(onsets))
    best = None
    lo, hi = C["align_search_s"]
    for off in np.arange(lo, hi + 1e-9, 0.02):
        sh = np.asarray(starts_rel) + off
        idx = np.clip(np.searchsorted(on, sh), 1, len(on) - 1)
        near = np.minimum(np.abs(on[idx] - sh), np.abs(on[idx - 1] - sh))
        hit = near <= C["align_tol_s"]
        score = (int(hit.sum()), -float(near[hit].mean()) if hit.any() else -9.0)
        if best is None or score > best[0]:
            best = (score, float(off))
    (hits, neg_err), off = best
    return {"offset_s": round(off, 2), "matched": hits, "speech": len(starts_rel),
            "onsets": len(onsets), "mean_err_s": round(-neg_err, 3) if hits else None}


def grab_frames(video, times_v, width=360):
    """요청 시각(영상 초)의 프레임. 탐색은 키프레임 단위라 최대 0.6초 앞에 떨어지므로
    (9/29 녹화 실측) 1.5초 앞으로 탐색한 뒤 요청 시각까지 프레임을 차례로 읽는다.
    시각은 CAP_PROP_POS_MSEC(가변 프레임 간격 — 메모리 screen-recordings-are-vfr)."""
    import cv2
    cap = cv2.VideoCapture(video)
    out = []
    for v in times_v:
        cap.set(cv2.CAP_PROP_POS_MSEC, max(v - 1.5, 0) * 1000.0)
        img, pos = None, None
        for _ in range(240):
            ok, frame = cap.read()
            if not ok:
                break
            img, pos = frame, cap.get(cv2.CAP_PROP_POS_MSEC) / 1000.0
            if pos >= v:
                break
        if img is None:
            out.append(None)
            continue
        h = int(img.shape[0] * width / img.shape[1])
        out.append((cv2.resize(img, (width, h)), pos))
    cap.release()
    return out


def contact_sheet(items, path, cols=4):
    """items: [(frame(BGR)|None, 실제 영상 초, 설명)] → 설명을 한글로 얹은 한 장."""
    from PIL import Image, ImageDraw, ImageFont
    frames = [it for it in items if it[0] is not None]
    if not frames:
        return False
    fw, fh = frames[0][0].shape[1], frames[0][0].shape[0]
    rows = math.ceil(len(frames) / cols)
    sheet = Image.new("RGB", (cols * fw, rows * (fh + 44)), (252, 252, 251))
    try:
        font = ImageFont.truetype("C:/Windows/Fonts/malgun.ttf", 15)
    except OSError:
        font = ImageFont.load_default()
    d = ImageDraw.Draw(sheet)
    for i, (img, vt, label) in enumerate(frames):
        x, y = (i % cols) * fw, (i // cols) * (fh + 44)
        sheet.paste(Image.fromarray(img[:, :, ::-1]), (x, y + 44))
        d.text((x + 6, y + 4), f"{int(vt // 60):02d}:{vt % 60:05.2f}", fill=(82, 81, 78), font=font)
        d.text((x + 6, y + 22), label[:28], fill=(11, 11, 11), font=font)
    sheet.save(path, quality=88)
    return True


# ---------------------------------------------------------------- 그림

INK, INK2, MUTED, GRID, AXIS, SURFACE = "#0b0b0b", "#52514e", "#898781", "#e1e0d9", "#c3c2b7", "#fcfcfb"
SLOT = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100"]   # 검증: dataviz validate_palette.js light PASS
WARN, CRIT = "#fab219", "#d03b3b"                     # 상태색(이탈=경고, 판정 없음=심각) — 행 이름과 함께만
STATE_ROWS = ["right", "left", "front", "hold", "approach", "crossed", "none", "nocall"]
VIB_KO = {"left": "왼쪽", "right": "오른쪽", "recover": "복귀", "road": "차도", "line_on": "블록 위"}
CUT = "#9ec5f4"  # 끊긴 음성: 같은 파랑의 옅은 단계(순차 램프 200) + 라벨 '(끊김)'


class _Stagger:
    """같은 줄 라벨이 겹치면 다음 줄로 내린다(창 폭 기준 글자 폭 추정)."""

    def __init__(self, t0, t1, rows=3):
        self.cw = (t1 - t0) / 160.0
        self.ends = [-1e18] * rows

    def place(self, x, text):
        for i, end in enumerate(self.ends):
            if x >= end:
                self.ends[i] = x + (len(text) + 1) * self.cw
                return i
        i = min(range(len(self.ends)), key=lambda k: self.ends[k])
        self.ends[i] = x + (len(text) + 1) * self.cw
        return i


def _legend_above(ax, ncol):
    ax.legend(loc="lower left", bbox_to_anchor=(0, 1.0), ncol=ncol, frameon=False, fontsize=8,
              borderaxespad=0.2, handlelength=1.6)


def _end_labels(ax, xs, series, names, min_gap):
    """선 끝 직접 라벨 — 값이 가까우면 위로 비켜 쌓는다."""
    pts = sorted(((ys[-1], n) for ys, n in zip(series, names)), key=lambda z: z[0])
    last = -1e9
    for y, n in pts:
        yy = max(y, last + min_gap)
        ax.annotate(n, (xs[-1], yy), xytext=(4, 0), textcoords="offset points", color=INK2,
                    fontsize=8, va="center", annotation_clip=False)
        last = yy


def _setup_mpl():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams.update({
        "font.family": ["Malgun Gothic", "DejaVu Sans"], "axes.unicode_minus": False,
        "font.size": 9, "axes.edgecolor": AXIS, "axes.labelcolor": INK2,
        "xtick.color": MUTED, "ytick.color": INK2, "axes.facecolor": SURFACE,
        "figure.facecolor": SURFACE, "axes.grid": True, "grid.color": GRID,
        "grid.linewidth": 0.6, "axes.spines.top": False, "axes.spines.right": False,
    })
    return plt


def plot_timeline(s, a, path, t0=None, t1=None, detail=False, title=""):
    """작은 배수(공유 시간축): 상태 / 분류기 확신 / 각도 / 노면 앞 칸 / 선형 좌·앞·우 /
    안내(음성·진동) / 소리 점유. detail=True면 문구·종류를 직접 적는다(확대 창용)."""
    plt = _setup_mpl()
    ser = a["_series"]
    t0 = s.start if t0 is None else t0
    t1 = s.end if t1 is None else t1
    rel = lambda t: t - s.start  # noqa: E731
    ev = [e for e in s.events if t0 <= e.t <= t1]
    fig, axes = plt.subplots(7, 1, figsize=(13, 13.5), sharex=True,
                             gridspec_kw={"height_ratios": [2.2, 1, 1, 1.4, 1, 2.0, 0.9]})
    ax = axes[0]
    for x in ser["iv"]:
        if x["b"] < t0 or x["a"] > t1 or x["st"] not in STATE_ROWS:
            continue
        y = STATE_ROWS.index(x["st"])
        col = WARN if x["st"] in DEVIATION else (CRIT if x["st"] == "nocall" else SLOT[0])
        ax.broken_barh([(rel(max(x["a"], t0)), min(x["b"], t1) - max(x["a"], t0))],
                       (y - 0.32, 0.64), facecolors=col, linewidth=0)
    ax.set_yticks(range(len(STATE_ROWS)), [STATE_KO[k] for k in STATE_ROWS])
    ax.set_ylim(len(STATE_ROWS) - 0.4, -0.6)
    ax.set_title(title or f"{s.name} — 화면 상태와 사용자가 받은 안내", loc="left", color=INK,
                 fontsize=11)
    ax.grid(axis="y", visible=False)

    ax = axes[1]
    cls = [e for e in ev if e.ev == "cls"]
    if cls:
        ax.plot([rel(e.t) for e in cls], [e.d.get("conf") or 0 for e in cls], color=SLOT[0], lw=1.3)
        low = [e for e in cls if not e.d.get("ok")]
        ax.plot([rel(e.t) for e in low], [e.d.get("conf") or 0 for e in low], "x", color=MUTED,
                ms=4, label="임계값 미달")
        if low:
            ax.legend(loc="lower left", frameon=False, fontsize=8)
    ax.axhline(0.55, color=AXIS, lw=0.9, ls=(0, (4, 3)))
    ax.set_ylim(0, 1.02)
    ax.set_ylabel("분류 확신")

    ax = axes[2]
    ang = [e for e in ev if e.ev == "angle" and e.d.get("smooth") is not None]
    if ang:
        ax.plot([rel(e.t) for e in ang], [e.d["smooth"] for e in ang], color=SLOT[0], lw=1.3)
    for yv in (CRITERIA["angle_enter_deg"], -CRITERIA["angle_enter_deg"]):
        ax.axhline(yv, color=AXIS, lw=0.9, ls=(0, (4, 3)))
    ax.set_ylabel("각도(°)")

    ax = axes[3]
    surf = [e for e in ev if e.ev == "surf" and e.d.get("ok")]
    if surf:
        xs = [rel(e.t) for e in surf]
        series = []
        for i, k in enumerate(SURF_KEYS):
            ys = [(e.d.get("F") or [0] * 4)[i] for e in surf]
            series.append(ys)
            ax.plot(xs, ys, color=SLOT[i], lw=1.3, label=SURF_KO[k])
        _end_labels(ax, xs, series, [SURF_KO[k] for k in SURF_KEYS], 0.13)
        _legend_above(ax, 4)
    ax.axhline(CRITERIA["surface_many"], color=AXIS, lw=0.9, ls=(0, (4, 3)))
    ax.axhline(CRITERIA["surface_present"], color=AXIS, lw=0.9, ls=(0, (4, 3)))
    ax.set_ylim(0, 1.02)
    ax.set_ylabel("노면 앞 칸")

    ax = axes[4]
    if surf:
        for i, (key, name) in enumerate((("L", "왼쪽"), ("F", "앞"), ("R", "오른쪽"))):
            ys = [(e.d.get(key) or [0] * 4)[2] for e in surf]
            ax.plot(xs, ys, color=SLOT[i], lw=1.3, label=name)
        _legend_above(ax, 3)
    ax.axhline(CRITERIA["surface_present"], color=AXIS, lw=0.9, ls=(0, (4, 3)))
    ax.set_ylim(bottom=0, top=max(0.1, ax.get_ylim()[1]))
    ax.set_ylabel("선형 비율")

    ax = axes[5]
    lanes = ["P0 음성", "P1 음성", "P2 음성", "P3 음성", "진동", "노면 이벤트"]
    cut_src = {x["src"] for x in a["missed"]["interrupted"]["items"]}
    stag = {i: _Stagger(rel(t0), rel(t1)) for i in range(len(lanes))}
    for sp in ser["played"]:
        if sp["b"] < t0 or sp["a"] > t1:
            continue
        y = int(sp["p"] or 0)
        cut = sp["src"] in cut_src
        ax.broken_barh([(rel(sp["a"]), sp["b"] - sp["a"])], (y - 0.3, 0.6),
                       facecolors=CUT if cut else SLOT[0], linewidth=0)
        if detail:
            text = sp["text"] + (" (끊김)" if cut else "")
            k = stag[y].place(rel(sp["a"]), text)
            # 0: 막대 위 / 1: 막대 아래 / 2: 더 위
            yy, va = [(y - 0.34, "bottom"), (y + 0.34, "top"), (y - 0.62, "bottom")][k]
            ax.annotate(text, (rel(sp["a"]), yy), fontsize=7.5, color=INK, va=va)
    for q in ser["reqs"]:
        if q.d.get("act") == "drop" and t0 <= q.t <= t1:
            y = int(q.d.get("p") or 0)
            ax.plot(rel(q.t), y, "x", color=CRIT, ms=6)
            if detail:
                text = f"버림({q.d.get('why')}): {q.d.get('text')}"
                k = stag[y].place(rel(q.t), text)
                ax.annotate(text, (rel(q.t), y + 0.42 + 0.22 * k), fontsize=7, color=INK2)
    for v in ser["vibs"]:
        if t0 <= v.t <= t1:
            ax.plot(rel(v.t), 4, "|", color=SLOT[1] if v.d.get("ok") else MUTED, ms=12, mew=2)
            if detail:
                text = VIB_KO.get(v.d.get("kind"), str(v.d.get("kind")))
                k = stag[4].place(rel(v.t), text)
                ax.annotate(text, (rel(v.t), 4.42 + 0.3 * k), fontsize=7.5, color=INK2, va="top")
    for e in ev:
        if e.ev == "surf.ev":
            ax.plot(rel(e.t), 5, "o", color=SLOT[2], ms=5)
            if detail:
                text = ",".join(e.d.get("names") or [])
                k = stag[5].place(rel(e.t), text)
                ax.annotate(text, (rel(e.t), 5.42 + 0.3 * k), fontsize=7.5, color=INK2, va="top")
    # 이탈 중 침묵 — 경고가 끊긴 구간을 상태색(경고) 옅은 띠 + 길이로 표시
    for ep in a["deviation"]["items"]:
        if ep["max_silence_s"] <= CRITERIA["danger_silence_s"]:
            continue
        a0, b0 = ep["start"], ep["start"] + ep["dur_s"]
        fb = sorted(f for f in [sp["a"] for sp in ser["played"] if sp["cat"] == "deviation"] +
                    [v.t for v in ser["vibs"] if v.d.get("ok") and v.d.get("kind") in DEVIATION]
                    if a0 - CRITERIA["feedback_lead_s"] <= f <= b0)
        edges = [a0] + fb + [b0]
        for g0, g1 in zip(edges, edges[1:]):
            if g1 - g0 > CRITERIA["danger_silence_s"] and g1 >= t0 and g0 <= t1:
                ax.axvspan(rel(max(g0, t0)), rel(min(g1, t1)), color=WARN, alpha=0.18, lw=0)
                ax.annotate(f"이탈 중 침묵 {g1 - g0:.1f}초", (rel(max(g0, t0)), 3.0),
                            xytext=(4, 0), textcoords="offset points", fontsize=8, color=INK)
    ax.set_yticks(range(len(lanes)), lanes)
    ax.set_ylim(len(lanes) + 0.1, -0.9)
    ax.grid(axis="y", visible=False)

    ax = axes[6]
    m = (ser["occ_t"] >= t0) & (ser["occ_t"] <= t1)
    ax.plot(ser["occ_t"][m] - s.start, ser["occ"][m], color=SLOT[0], lw=1.3)
    ax.axhline(CRITERIA["occupancy_limit_s"], color=AXIS, lw=0.9, ls=(0, (4, 3)))
    ax.set_ylim(bottom=0)
    ax.set_ylabel("60초 음성(초)")
    ax.set_xlabel("기록 시작부터 초")
    ax.set_xlim(rel(t0), rel(t1))
    fig.align_ylabels(axes)
    fig.tight_layout()
    fig.savefig(path, dpi=110)
    plt.close(fig)


# ---------------------------------------------------------------- 보고서

def strip_series(a):
    return {k: v for k, v in a.items() if not k.startswith("_")}


def write_report(out, sessions, analyses, scenes, align, bad, unknown):
    L = []
    tot = lambda f: sum(f(analyses[s.name]) for s in sessions)  # noqa: E731
    dev_n = tot(lambda a: a["deviation"]["episodes"])
    silent_n = tot(lambda a: a["deviation"]["silent_episodes"]["n"])
    miss_n = tot(lambda a: a["missed"]["dropped"]["n"] + a["missed"]["expired_in_queue"]["n"])
    intr_n = tot(lambda a: a["missed"]["interrupted"]["n"])
    L.append(f"### 결론: 이탈 {dev_n}회 중 침묵 {silent_n}회, 못 들은 안내 {miss_n}개, "
             f"끊긴 안내 {intr_n}개 (세션 {len(sessions)}개)")
    L.append("")
    L.append("| 항목 | 결과 | 이전/기준값 | 근거 (파일:줄) |")
    L.append("|---|---|---|---|")
    for s in sessions:
        a = analyses[s.name]
        d, m, st, so, pr, su = (a["deviation"], a["missed"], a["stability"], a["sound"],
                                a["processing"], a["surface"])
        first = lambda xs: xs[0] if xs else "-"  # noqa: E731
        L.append(f"| [{s.name}] 길이 | {a['duration_s']}초 | — | {s.events[0].src} |")
        L.append(f"| 이탈 경고 첫 반응 | p50 {d['first_feedback_s'].get('p50', '-')}초 · "
                 f"max {d['first_feedback_s'].get('max', '-')}초 (n={d['episodes']}) | — | "
                 f"{first([x['src'] for x in d['items']])} |")
        L.append(f"| 각도 근거 → 이탈 상태 | p50 {d['evidence_to_state_s'].get('p50', '-')}초 "
                 f"(n={d['evidence_to_state_s'].get('n', 0)}) | — | — |")
        L.append(f"| 이탈 중 침묵 | {d['silent_episodes']['n']}회 | {CRITERIA['danger_silence_s']}초 초과 | "
                 f"{first([x['src'] for x in d['silent_episodes']['items']])} |")
        L.append(f"| 경고를 받은 경로 | {d['channels']} | — | — |")
        L.append(f"| 못 들은 안내(버림) | {m['dropped']['n']}개 {m['dropped']['by_reason']} | — | "
                 f"{first([x['src'] for x in m['dropped']['items']])} |")
        L.append(f"| 대기 중 만료 | {m['expired_in_queue']['n']}개 | — | "
                 f"{first(m['expired_in_queue']['src'])} |")
        L.append(f"| 끊긴 안내 | {m['interrupted']['n']}개 | — | "
                 f"{first([x['src'] for x in m['interrupted']['items']])} |")
        L.append(f"| 상태 깜빡임 | {st['flicker']['n']}회 · 분당 상태 변화 {st['state_changes_per_min']} | "
                 f"{CRITERIA['flicker_s']}초 안 되돌아옴 | {first([x['src'] for x in st['flicker']['items']])} |")
        L.append(f"| 판정 없음 | 합계 {st['no_guidance']['total_s']}초 ({st['no_guidance']['share'] * 100:.1f}%) · "
                 f"최장 {st['no_guidance']['longest_s']}초 | — | {st['no_guidance']['longest_src'] or '-'} |")
        L.append(f"| 소리 점유 | 최대 {so['occupancy_max_s']}초/60초 · 한도 초과 {so['occupancy_over_limit_s']}초 | "
                 f"{so['occupancy_limit_s']}초 | — |")
        L.append(f"| 반복 안내 | {so['repeats']} | {CRITERIA['repeat_s']}초 안 | — |")
        L.append(f"| 받은 음성 / 진동 | {a['received']['speech_by_category']} / {a['received']['vibration_by_kind']} | — | — |")
        L.append(f"| 노면 변화 반응 | {su['reactions']} · 반응 p50 {su['reaction_s'].get('p50', '-')}초 | "
                 f"{CRITERIA['surface_event_wait_s']}초 안 | "
                 f"{first([x['src'] for x in su['no_reaction_items']])} |")
        L.append(f"| 처리 시간 | 분류 p50 {pr['cls_ms'].get('p50', '-')}ms · 노면 p50 {pr['surf_ms'].get('p50', '-')}ms | "
                 f"분류 83~88ms · 노면 96~99ms (T104 실측) | — |")
        L.append(f"| 처리 공백 | {pr['stalls']['n']}회 · 최장 {pr['stalls']['longest_s']}초 | "
                 f"{CRITERIA['stall_s']}초 초과 | — |")
    if scenes:
        L.append("")
        L.append("#### 장면별 (앱 동작 × 사용자 체감)")
        L.append("| 장면 | 사용자 | 앱 | 판정 | 창 안에서 찾은 것 / 빠진 것 |")
        L.append("|---|---|---|---|---|")
        for r in scenes:
            app = "-" if r.get("app") is None else ("됨" if r["app"] else "안 됨")
            L.append(f"| {r['scene']} {r['title']} | {r['user']} | {app} | {r['verdict']} | "
                     f"{r.get('found', '')} {'; '.join(r.get('why', []))} |")
    if align:
        L.append("")
        L.append("#### 영상 정렬")
        for v in align:
            L.append(f"- {v['video']}: {v}")
    if bad or unknown:
        L.append("")
        L.append(f"### 문제/다음 단계: 형식이 다른 줄 {len(bad)}개, 모르는 사건 {unknown} — "
                 "summary.json의 bad_lines 샘플 확인 필요")
    open(os.path.join(out, "report.md"), "w", encoding="utf-8").write("\n".join(L) + "\n")


def run(paths, out, videos=(), checklist=None, scene_video=None, tz=9, offset=None,
        scene_start=None):
    os.makedirs(out, exist_ok=True)
    sessions, bad, unknown = load_sessions(paths)
    if not sessions:
        raise SystemExit("기록이 없습니다")
    msgmap = load_message_map()
    analyses = {s.name: analyze_session(s, msgmap) for s in sessions}

    align = []
    for v in videos:
        rs = recording_start(v, tz)
        info = {"video": os.path.basename(v), "start_epoch": rs}
        if rs is None:
            info["error"] = "파일 이름에서 시작 시각을 못 읽음"
            align.append(info)
            continue
        starts = [sp["a"] - rs for s in sessions for sp in analyses[s.name]["_series"]["played"]]
        starts = [x for x in starts if x >= -10]
        onsets, note = audio_onsets(v)
        info["audio"] = note
        est = estimate_offset(starts, onsets or [])
        info.update(est or {"offset_s": None})
        if offset is not None:
            info["offset_s"] = offset
            info["offset_source"] = "--offset"
        elif est and est["matched"] >= 3:
            info["offset_source"] = "소리 정렬"
        else:
            info["offset_s"] = 0.0
            info["offset_source"] = "파일 이름만(소리 정렬 실패 — 1초 안팎 오차 가능)"
        align.append(info)

    scenes = None
    if checklist:
        ck = json.load(open(checklist, encoding="utf-8"))
        sv = scene_video or (videos[0] if videos else None)
        al = next((x for x in align if sv and x["video"] == os.path.basename(sv)), None)
        rs = al["start_epoch"] if al else scene_start
        scenes = judge_scenes(ck, sessions, analyses, rs, (al["offset_s"] or 0.0) if al else 0.0)

    for s in sessions:
        a = analyses[s.name]
        base = os.path.splitext(s.name)[0]
        plot_timeline(s, a, os.path.join(out, f"timeline_{base}.png"))
        for i, ep in enumerate(a["deviation"]["items"][:12]):
            plot_timeline(s, a, os.path.join(out, f"window_{base}_dev{i + 1}.png"),
                          ep["start"] - 6, ep["start"] + ep["dur_s"] + 6, detail=True,
                          title=f"이탈 {i + 1}: {STATE_KO.get(ep['state'])} {ep['dur_s']}초 ({ep['src']})")
        if scenes:
            for r in scenes:
                if r.get("window") and r.get("session") == s.name:
                    lo, hi = r["window"]
                    plot_timeline(s, a, os.path.join(out, f"window_{base}_scene{r['scene']}.png"),
                                  lo - 3, hi + 3, detail=True,
                                  title=f"장면 {r['scene']} {r['title']} — 사용자 {r['user']}, {r['verdict']}")

    for info in align:
        if info.get("start_epoch") is None or info.get("offset_s") is None:
            continue
        vpath = next(v for v in videos if os.path.basename(v) == info["video"])
        rs, off = info["start_epoch"], info["offset_s"]
        picks = []
        for s in sessions:
            a = analyses[s.name]
            picks += [(e.t, "노면 " + ",".join(e.d.get("names") or [])) for e in s.events if e.ev == "surf.ev"]
            picks += [(ep["start"], f"이탈 시작 {ep['state']}") for ep in a["deviation"]["items"]]
            picks += [(v.t, f"진동 {v.d.get('kind')}") for v in a["_series"]["vibs"]]
        picks = sorted({p for p in picks if 0 <= p[0] - rs + off})[:48]
        frames = grab_frames(vpath, [t - rs + off for t, _ in picks])
        items = [(f[0], f[1], lab) if f else (None, 0, lab) for f, (_, lab) in zip(frames, picks)]
        contact_sheet(items, os.path.join(out, f"frames_{os.path.splitext(info['video'])[0]}.jpg"))

    summary = {"criteria": {k: list(v) if isinstance(v, tuple) else v for k, v in CRITERIA.items()},
               "criteria_status": "초안 — 사용자 확인 전",
               "sessions": [strip_series(analyses[s.name]) for s in sessions],
               "scenes": scenes, "video_alignment": align,
               "bad_lines": {"n": len(bad), "sample": bad[:20]}, "unknown_events": unknown}
    json.dump(summary, open(os.path.join(out, "summary.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1, default=str)
    write_report(out, sessions, analyses, scenes, align, bad, unknown)
    return summary


# ---------------------------------------------------------------- 자체 검증(합성 기록)

def _selftest():
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from field_log_sample_t106 import EXPECT, write_sample
    out = os.path.join(REPO, "train", "field_t106", "selftest")
    os.makedirs(out, exist_ok=True)
    log_path, ck_path, rec_start = write_sample(out)
    sessions, bad, unknown = load_sessions([log_path])
    msgmap = load_message_map()
    a = analyze_session(sessions[0], msgmap)
    got = {
        "episodes": a["deviation"]["episodes"],
        "silent": a["deviation"]["silent_episodes"]["n"],
        "flicker": a["stability"]["flicker"]["n"],
        "interrupted": a["missed"]["interrupted"]["n"],
        "dropped": a["missed"]["dropped"]["n"],
        "dropped_reasons": a["missed"]["dropped"]["by_reason"],
        "stalls": a["processing"]["stalls"]["n"],
        "no_guidance_s": a["stability"]["no_guidance"]["total_s"],
        "surface_events": a["surface"]["events"],
        "reactions": a["surface"]["reactions"],
        "evidence_n": a["deviation"]["evidence_to_state_s"]["n"],
        "evidence_p50": a["deviation"]["evidence_to_state_s"].get("p50"),
        "on_block_p50": a["surface"]["on_block_s"].get("p50"),
        "vib": a["received"]["vibration_by_kind"],
        "repeats": sum(a["sound"]["repeats"].values()),
        "occ_under_limit": a["sound"]["occupancy_max_s"] < CRITERIA["occupancy_limit_s"],
    }
    ok = True
    for k, v in EXPECT.items():
        flag = "OK " if got[k] == v else "BAD"
        ok &= got[k] == v
        print(f"  [{flag}] {k}: {got[k]} (기대 {v})")
    starts = [sp["a"] - rec_start for sp in a["_series"]["played"]]
    fake_onsets = [x + 2.37 + (0.04 if i % 2 else -0.03) for i, x in enumerate(starts)]
    est = estimate_offset(starts, fake_onsets + [3.3, 47.1])
    flag = "OK " if est and abs(est["offset_s"] - 2.37) <= 0.06 else "BAD"
    ok &= flag == "OK "
    print(f"  [{flag}] offset 추정: {est} (기대 2.37±0.06)")
    ck = json.load(open(ck_path, encoding="utf-8"))
    scenes = judge_scenes(ck, sessions, {sessions[0].name: a}, rec_start, 0.0)
    want = {"A": "정상", "B": "정상", "E": QUADRANT[(True, "fail")], "F": "정상", "G": "정상"}
    for r in scenes:
        if r["scene"] in want:
            flag = "OK " if r["verdict"] == want[r["scene"]] else "BAD"
            ok &= flag == "OK "
            print(f"  [{flag}] 장면 {r['scene']}: {r['verdict']} {r.get('why', '')}")
    run([log_path], out, checklist=ck_path, scene_start=rec_start)
    print(f"출력: {out}")
    print("자체 검증:", "통과" if ok else "실패")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("logs", nargs="*")
    ap.add_argument("--out", default=os.path.join(REPO, "train", "field_t106", "latest"))
    ap.add_argument("--video", nargs="*", default=[])
    ap.add_argument("--checklist")
    ap.add_argument("--scene-video")
    ap.add_argument("--tz", type=float, default=9.0, help="폰 시간대(시간). 한국 9")
    ap.add_argument("--offset", type=float, help="영상 시각 보정(초) — 주면 소리 정렬 대신 사용")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        raise SystemExit(_selftest())
    if not args.logs:
        ap.error("기록 파일(.jsonl)을 주세요")
    run(args.logs, args.out, args.video, args.checklist, args.scene_video, args.tz, args.offset)
    print(open(os.path.join(args.out, "report.md"), encoding="utf-8").read())


if __name__ == "__main__":
    main()
