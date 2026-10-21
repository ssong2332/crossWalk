"""T109 비율 맞춤 비교 — 화각 효과와 화면 비율 효과를 나눈다 (추론만, 학습 없음).

왜: 모델 3종은 폰 세로 사진(화면 기준 3:4 세로, 학습 사진 600/600장 w/h=0.75, EXIF 회전 6)으로 학습했는데
    W108·W90 크롭은 16:9 가로라 224x224로 줄일 때 가로로 약 2.4배 더 눌린다. 화각과 비율이 동시에 바뀐다.
기준: 학습 입력과 같은 '화면 세로 3:4'로 맞춘다. 원본이 가로 16:9라 화각을 유지하면서 3:4 세로를 만들려면
    위아래를 채워야 한다(가로 유지). 높이를 유지하면 3:4로 잘라 화각이 좁아진다(세로 유지). 둘 다 잰다.
  W108pad  1920x1080 위아래를 평균색으로 채워 1920x2560 (가로 약 108도 유지, 눌림 없음)
  W90pad   1386x780 → 1386x1848 (약 90도 유지)
  W108c34  가운데 810x1080 (가로 약 60도, 추정)
  W90c34   가운데 585x780 (가로 약 45도, 추정)
  채움색   ImageNet 평균 RGB(124,116,104) — 정규화 후 0에 가까운 중립값
장면·모델 입력·판정·지표는 train/h0_t109_eval.py를 그대로 가져다 쓴다(그 파일은 수정하지 않음).
첫 영상만 W108을 함께 돌려 10/17 frames.csv와 같은 값이 나오는지 확인한다.

사용: python train/h0_t109/aspect_cmp/aspect_cmp.py  (저장소 루트에서)
"""
import csv, json, os, re, sys, glob
from pathlib import Path
import cv2, numpy as np

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "train"))
import h0_t109_eval as E  # noqa: E402

OUT = Path(__file__).resolve().parent
PAD = (124, 116, 104)  # RGB
NEW = ["W108pad", "W90pad", "W108c34", "W90c34"]
ALL = ["W108", "W90", "P50"] + NEW
OK = {"C1": "front", "C2": "left", "C3": "right", "C4": "left", "C5": "right"}


def pad34(rgb):
    h, w = rgb.shape[:2]; th = int(round(w * 4 / 3)); top = (th - h) // 2
    out = np.empty((th, w, 3), np.uint8); out[:] = PAD; out[top:top + h] = rgb
    return out


def make(rgb_full, name):
    if name == "W108": return E.center_crop(rgb_full, 1920, 1080)
    if name == "W108pad": return pad34(rgb_full)
    if name == "W90pad": return pad34(E.center_crop(rgb_full, 1386, 780))
    if name == "W108c34": return E.center_crop(rgb_full, 810, 1080)
    if name == "W90c34": return E.center_crop(rgb_full, 585, 780)
    raise ValueError(name)


def infer(rgb):
    lg = E.run("c", E.cls_t(rgb)); e = np.exp(lg - lg.max()); pr = e / e.sum()
    a = float(E.run("a", E.reg_t(rgb, 224 / 288))[0]) * 90.0
    pos = float(E.run("p", E.reg_t(rgb, 1.0))[0]) * 2.0
    lab, conf, passed = E.cls_label(pr)
    return lab, conf, passed, a, pos


def pct(k, n): return None if n == 0 else round(100.0 * k / n, 1)


def summarize(R):
    by = lambda *cs: [r for r in R if r["cond"] in cs]
    c1, c2, c3, c4, c5, s123 = by("C1"), by("C2"), by("C3"), by("C4"), by("C5"), by("C1", "C2", "C3")
    return {
        "n": len(R),
        "left_edge_hit": [pct(sum(r["pos"] <= -1 for r in c2), len(c2)), len(c2)],
        "right_edge_hit": [pct(sum(r["pos"] >= 1 for r in c3), len(c3)), len(c3)],
        "c1_false_edge": [pct(sum(abs(r["pos"]) >= 1 for r in c1), len(c1)), len(c1)],
        "straight_angle_front": [pct(sum(r["adir"] == "front" for r in s123), len(s123)), len(s123)],
        "diag_correct": [pct(sum(r["adir"] == "left" for r in c4) + sum(r["adir"] == "right" for r in c5), len(c4) + len(c5)), len(c4) + len(c5)],
        "diag_reverse": [pct(sum(r["adir"] == "right" for r in c4) + sum(r["adir"] == "left" for r in c5), len(c4) + len(c5)), len(c4) + len(c5)],
        "on_crosswalk_cls": [pct(sum(r["cls"] in ("front", "left", "right") and r["passed"] for r in R), len(R)), len(R)],
        "no_decision": [pct(sum(not r["passed"] for r in R), len(R)), len(R)],
        "none_count": sum(r["cls"] == "none" for r in R),
        "final_correct": [pct(sum(r["final"] == OK[r["cond"]] for r in R), len(R)), len(R)],
        "abs_angle_median_c45": round(float(np.median([abs(r["angle"]) for r in c4 + c5])), 1) if c4 + c5 else None,
    }


def main():
    vids = [(p, "day") for p in sorted(glob.glob(str(ROOT / "videos/h0/*.mp4")))] + \
           [(p, "night") for p in sorted(glob.glob(str(ROOT / "videos/h0/night/*.mp4")))]
    rows = []
    for vi, (p, light) in enumerate(vids):
        m = re.search(r"_([cC][1-5])\.mp4$", p)
        if not m: print("조건 없음, 건너뜀:", p); continue
        cond = m.group(1).upper(); crops = (["W108"] if vi == 0 else []) + NEW
        for i, t, dur, fr in E.frames(p):
            rgb_full = cv2.cvtColor(fr, cv2.COLOR_BGR2RGB)
            for cname in crops:
                lab, conf, passed, a, pos = infer(make(rgb_full, cname))
                rows.append(dict(video=os.path.basename(p), light=light, cond=cond, crop=cname, frame=i,
                                 t=round(t, 2), dur=round(dur, 2), cls=lab, conf=round(conf, 3), passed=int(passed),
                                 angle=round(a, 2), pos=round(pos, 3), adir=E.angle_dir(a),
                                 final=E.resolve(lab, a, pos) if passed else "(무판정)"))
        print("완료", os.path.basename(p), cond, light, flush=True)
    with open(OUT / "frames_aspect.csv", "w", newline="", encoding="utf-8") as f:
        wr = csv.DictWriter(f, fieldnames=list(rows[0].keys())); wr.writeheader(); wr.writerows(rows)

    # 10/17 결과(W108/W90/P50)를 같은 형식으로 읽어 나란히 둔다
    old = []
    for r in csv.DictReader(open(ROOT / "train/h0_t109/frames.csv", encoding="utf-8")):
        r = dict(r); r["passed"] = int(r["passed"]); r["pos"] = float(r["pos"]); r["angle"] = float(r["angle"]); old.append(r)
    # 재현 확인: 첫 영상 W108이 10/17과 같은가
    key = lambda r: (r["video"], int(r["frame"]), r["crop"])
    o = {key(r): r for r in old}
    chk = [r for r in rows if r["crop"] == "W108"]
    same = all(abs(o[key(r)]["pos"] - r["pos"]) < 1e-6 and abs(o[key(r)]["angle"] - r["angle"]) < 1e-6
               and o[key(r)]["cls"] == r["cls"] for r in chk)
    new_rows = [r for r in rows if r["crop"] != "W108"]
    allr = old + new_rows
    summary = {f"{light}/{c}": summarize([r for r in allr if r["light"] == light and r["crop"] == c])
               for light in ("day", "night") for c in ALL}
    per_video = {}
    for r in allr:
        k = f'{r["video"]}|{r["cond"]}|{r["crop"]}'
        d = per_video.setdefault(k, {"n": 0, "edge": 0, "diag": 0, "final": 0})
        d["n"] += 1
        d["edge"] += int((r["cond"] == "C2" and r["pos"] <= -1) or (r["cond"] == "C3" and r["pos"] >= 1))
        d["diag"] += int((r["cond"] == "C4" and r["adir"] == "left") or (r["cond"] == "C5" and r["adir"] == "right"))
        d["final"] += int(r["final"] == OK[r["cond"]])
    json.dump({"pad_rgb": PAD, "check_first_video_W108_equals_1017": same, "n_check": len(chk),
               "summary": summary, "per_video": per_video},
              open(OUT / "summary_aspect.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("재현 확인(첫 영상 W108 == 10/17):", same, len(chk))


if __name__ == "__main__":
    main()
