"""T109 H0 화각 시험 — 폰 초광각 가로 영상을 3가지 화각으로 잘라 배포 모델 3종에 넣는다.

판정 기준표(사용자 확인 2026-10-17):
  화각  W108 원본 / W90 가운데 72%(1386x780) / P50 가운데 646x860(폰 세로 근사, 가로 약 50도 추정)
  장면  시작 2.5초 뒤 ~ 끝 1.0초 전, 초당 3장
  입력  앱과 동일 — 분류(센서 방향=반시계 90도)·위치는 자른 화면 전체를 224, 각도는 가운데 224/288
  정답  C1 안쪽 / C2 왼쪽 끝 / C3 오른쪽 끝 (방향 직진) · C4 왼쪽으로 틀어짐 · C5 오른쪽으로 틀어짐
  판정  direction_resolver.dart: 이탈 12도, 끝 |위치|>=1. 각도 +는 왼쪽 이탈(left), -는 오른쪽(right).

사용: python train/h0_t109_eval.py  (저장소 루트에서)
"""
import csv, glob, hashlib, json, os, re, sys
from pathlib import Path
import cv2, numpy as np, onnxruntime as ort

ROOT = Path(__file__).resolve().parent.parent
A = ROOT / "crosswalk_app" / "assets" / "model"
OUT = ROOT / "train" / "h0_t109"
LABELS = ["none", "approach", "front", "left", "right", "crossed"]
TH = {"front": 0.40, "none": 0.40, "approach": 0.55, "crossed": 0.55}  # classifier.dart
DEV_TH = 0.55
DEV_DEG, EDGE_POS, EDGE_STEER = 12.0, 1.0, 20.0  # direction_resolver.dart
MEAN = np.array([0.485, 0.456, 0.406], np.float32); STD = np.array([0.229, 0.224, 0.225], np.float32)
IMG, GRID = 224, 3
CROPS = {"W108": (1920, 1080), "W90": (1386, 780), "P50": (646, 860)}
T_START, T_END_MARGIN, STEP_S = 2.5, 1.0, 1.0 / 3


def norm(a): return ((a / 255.0 - MEAN) / STD).transpose(2, 0, 1)[None].astype(np.float32)
def cls_t(rgb):
    """분류기는 EXIF 회전 미적용(센서 방향)으로 학습·추론한다(screenshot_probe_0908.py:13, classifier.dart는
    회전하지 않음). 세운 화면을 반시계 90도 돌려 센서 방향으로 되돌린다 — 표본 확인: C5 19장 중 right 15(회전 없이 0)."""
    raw = cv2.rotate(rgb, cv2.ROTATE_90_COUNTERCLOCKWISE)
    return norm(cv2.resize(raw, (IMG, IMG), interpolation=cv2.INTER_AREA).astype(np.float32))
def reg_t(rgb, crop):
    arr = rgb.astype(np.float32); dh, dw = arr.shape[:2]; cw, ch = int(dw * crop), int(dh * crop)
    ox, oy = (dw - cw) // 2, (dh - ch) // 2
    ys = oy + (np.arange(IMG * GRID) * ch) // (IMG * GRID); xs = ox + (np.arange(IMG * GRID) * cw) // (IMG * GRID)
    return norm(arr[np.ix_(ys, xs)].reshape(IMG, GRID, IMG, GRID, 3).mean(axis=(1, 3)))


S = {k: ort.InferenceSession(str(A / f), providers=["CPUExecutionProvider"]) for k, f in
     [("c", "crosswalk_model.onnx"), ("a", "crosswalk_angle.onnx"), ("p", "crosswalk_position.onnx")]}
def run(k, x): s = S[k]; return np.asarray(s.run(None, {s.get_inputs()[0].name: x})[0]).ravel()


def center_crop(fr, w, h):
    H, W = fr.shape[:2]; x0, y0 = (W - w) // 2, (H - h) // 2
    return fr[y0:y0 + h, x0:x0 + w]


def angle_dir(a): return "left" if a >= DEV_DEG else ("right" if a <= -DEV_DEG else "front")


def resolve(label, a, pos):
    """DirectionResolver.resolve, previous 없음(장면을 서로 독립으로 본다)."""
    if label not in ("front", "left", "right"): return label
    if pos <= -EDGE_POS: return "front" if a <= -DEV_DEG else "left"
    if pos >= EDGE_POS: return "front" if a >= DEV_DEG else "right"
    return angle_dir(a)


def cls_label(pr):
    i = int(np.argmax(pr)); lab = LABELS[i]
    return lab, float(pr[i]), float(pr[i]) >= TH.get(lab, DEV_TH)


def frames(path):
    cap = cv2.VideoCapture(path); n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT)); fps = cap.get(cv2.CAP_PROP_FPS)
    dur = n / fps; t_next = T_START; i = 0
    while True:
        ok, fr = cap.read()
        if not ok: break
        t = cap.get(cv2.CAP_PROP_POS_MSEC) / 1000.0
        if t > dur - T_END_MARGIN: break
        if t >= t_next:
            yield i, t, dur, fr; t_next += STEP_S
        i += 1


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    vids = [(p, "day") for p in sorted(glob.glob(str(ROOT / "videos/h0/*.mp4")))] + \
           [(p, "night") for p in sorted(glob.glob(str(ROOT / "videos/h0/night/*.mp4")))]
    rows = []
    for p, light in vids:
        m = re.search(r"_([cC][1-5])\.mp4$", p)
        if not m: print("조건 없음, 건너뜀:", p); continue
        cond = m.group(1).upper()
        for i, t, dur, fr in frames(p):
            rgb_full = cv2.cvtColor(fr, cv2.COLOR_BGR2RGB)
            for cname, (w, h) in CROPS.items():
                rgb = center_crop(rgb_full, w, h)
                lg = run("c", cls_t(rgb)); e = np.exp(lg - lg.max()); pr = e / e.sum()
                a = float(run("a", reg_t(rgb, 224 / 288))[0]) * 90.0
                pos = float(run("p", reg_t(rgb, 1.0))[0]) * 2.0
                lab, conf, passed = cls_label(pr)
                rows.append(dict(video=os.path.basename(p), light=light, cond=cond, crop=cname, frame=i,
                                 t=round(t, 2), dur=round(dur, 2), cls=lab, conf=round(conf, 3), passed=int(passed),
                                 angle=round(a, 2), pos=round(pos, 3), adir=angle_dir(a),
                                 final=resolve(lab, a, pos) if passed else "(무판정)"))
        print("완료", os.path.basename(p), cond, light, flush=True)
    with open(OUT / "frames.csv", "w", newline="", encoding="utf-8") as f:
        wr = csv.DictWriter(f, fieldnames=list(rows[0].keys())); wr.writeheader(); wr.writerows(rows)

    def pct(k, n): return None if n == 0 else round(100.0 * k / n, 1)
    summary = {}
    for light in ("day", "night"):
        for cname in CROPS:
            R = [r for r in rows if r["light"] == light and r["crop"] == cname]
            by = lambda *cs: [r for r in R if r["cond"] in cs]
            c1, c2, c3, c4, c5, s123 = by("C1"), by("C2"), by("C3"), by("C4"), by("C5"), by("C1", "C2", "C3")
            summary[f"{light}/{cname}"] = {
                "n": len(R),
                "left_edge_hit": [pct(sum(r["pos"] <= -1 for r in c2), len(c2)), len(c2)],
                "right_edge_hit": [pct(sum(r["pos"] >= 1 for r in c3), len(c3)), len(c3)],
                "c1_false_edge": [pct(sum(abs(r["pos"]) >= 1 for r in c1), len(c1)), len(c1)],
                "straight_angle_front": [pct(sum(r["adir"] == "front" for r in s123), len(s123)), len(s123)],
                "straight_final_front": [pct(sum(r["final"] == "front" for r in s123), len(s123)), len(s123)],
                "diag_reverse": [pct(sum(r["adir"] == "right" for r in c4) + sum(r["adir"] == "left" for r in c5),
                                     len(c4) + len(c5)), len(c4) + len(c5)],
                "diag_correct": [pct(sum(r["adir"] == "left" for r in c4) + sum(r["adir"] == "right" for r in c5),
                                     len(c4) + len(c5)), len(c4) + len(c5)],
                "on_crosswalk_cls": [pct(sum(r["cls"] in ("front", "left", "right") and r["passed"] for r in R), len(R)), len(R)],
                "no_decision": [pct(sum(not r["passed"] for r in R), len(R)), len(R)],
                "cls_counts": {l: sum(r["cls"] == l for r in R) for l in LABELS},
            }
    sha = {f: hashlib.sha256((A / f).read_bytes()).hexdigest()[:12] for f in
           ["crosswalk_model.onnx", "crosswalk_angle.onnx", "crosswalk_position.onnx"]}
    json.dump({"models": sha, "summary": summary}, open(OUT / "summary.json", "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    print(json.dumps({"models": sha, "summary": summary}, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
