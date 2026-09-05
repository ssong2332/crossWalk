"""T76 후속 — 흔들림 개선(26.1%->14.0%)이 신규 54장 때문인지 인과 검증.

방법 (추측 없이 실측):
  1. 811 CV(train/groupkfold_5class_out_811/all_probs.json)와
     865 CV(train/groupkfold_5class_out/all_probs.json)에서 파일명을 비교해
     신규 54장을 식별한다(이미 진행 대화에서 확인: right+21/left+20/front+9/approach+4).
  2. EXIF DateTimeOriginal로 클래스별 시간순 정렬 후, 인접한 두 장의 간격이
     5초 이내면 "연속쌍"으로 삼는다(T72/T76과 동일 정의).
  3. "OLD_PAIRS" = 811장만으로 시간순 정렬했을 때 나오는 연속쌍(신규 54장이
     존재하지 않았을 때의 진짜 쌍 집합 — T72 원본 재현).
  4. 판정(state) = argmax 확률 라벨의 임계값(T73: front/none/approach=0.40,
     left/right=0.55) 통과 여부. 미통과면 '무판정'.
  5. 비교:
     a) OLD_PAIRS x 811-CV 예측  -> 재현값 (T72 원 실측과 대조)
     b) OLD_PAIRS x 865-CV 예측  -> 새 모델이 "같은 옛 장면"에서도 나아졌는지
     c) 865 전체쌍 x 865-CV 예측 -> T76 보고값(14.0%) 재현
  (a)~(b) 차이가 거의 없는데 (b)~(c) 차이가 크면: 흔들림 감소는 모델이
  일반화를 더 잘해서가 아니라 "신규 쌍 자체가 쉬워서" 평균을 끌어내린 것.
  (a)~(b)에서도 크게 줄면: 새 데이터가 옛 장면에 대한 일반화도 실제로 개선.
"""
import json
import os
from collections import defaultdict
from datetime import datetime
from pathlib import Path

from PIL import Image
import PIL.ExifTags as ExifTags

REPO = Path(__file__).resolve().parent.parent
DATA_DIR = REPO / "image"
CLASS_DIRS = ["0_none", "1_approach", "2_front", "3_left", "4_right"]
CLASSES = ["none", "approach", "front", "left", "right"]

THRESHOLDS = {"front": 0.40, "none": 0.40, "approach": 0.40, "left": 0.55, "right": 0.55}
GAP_SEC = 5.0


def load_exif_dt():
    dt_map = {}
    cls_map = {}
    for cls_dir, cls in zip(CLASS_DIRS, CLASSES):
        d = DATA_DIR / cls_dir
        if not d.is_dir():
            continue
        for f in sorted(os.listdir(d)):
            if not f.lower().endswith((".jpg", ".jpeg", ".png")):
                continue
            p = d / f
            ex = Image.open(p)._getexif() or {}
            dt = None
            for k, v in ex.items():
                if ExifTags.TAGS.get(k) == "DateTimeOriginal":
                    dt = datetime.strptime(v, "%Y:%m:%d %H:%M:%S")
            if dt is None:
                raise RuntimeError(f"EXIF 촬영시각 없음: {p}")
            dt_map[f] = dt
            cls_map[f] = cls
    return dt_map, cls_map


def adjacent_pairs(files, dt_map, cls_map):
    """파일 부분집합만으로 클래스별 시간순 정렬 후 인접쌍(간격<=5s)을 뽑는다."""
    by_cls = defaultdict(list)
    for f in files:
        by_cls[cls_map[f]].append(f)
    pairs = []
    for cls, fl in by_cls.items():
        fl.sort(key=lambda f: dt_map[f])
        for a, b in zip(fl, fl[1:]):
            gap = (dt_map[b] - dt_map[a]).total_seconds()
            if 0 <= gap <= GAP_SEC:
                pairs.append((a, b, cls))
    return pairs


def decide(probs):
    best_label = max(probs, key=probs.get)
    conf = probs[best_label]
    if conf < THRESHOLDS[best_label]:
        return "무판정"
    return best_label


def flip_rate(pairs, prob_lookup):
    n = 0
    flips = 0
    missing = 0
    detail = defaultdict(int)
    for a, b, cls in pairs:
        if a not in prob_lookup or b not in prob_lookup:
            missing += 1
            continue
        da = decide(prob_lookup[a])
        db = decide(prob_lookup[b])
        n += 1
        if da != db:
            flips += 1
            detail[f"{da}->{db}"] += 1
    return n, flips, missing, detail


def main():
    probs_811 = {r["file"]: r["probs"] for r in json.load(
        open(REPO / "train/groupkfold_5class_out_811/all_probs.json", encoding="utf-8"))}
    probs_865 = {r["file"]: r["probs"] for r in json.load(
        open(REPO / "train/groupkfold_5class_out/all_probs.json", encoding="utf-8"))}

    old_files = set(probs_811.keys())
    all_files = set(probs_865.keys())
    new_files = all_files - old_files
    print(f"811 파일수: {len(old_files)}  865 파일수: {len(all_files)}  신규: {len(new_files)}")
    assert len(new_files) == 54, f"신규 파일수 불일치: {len(new_files)} (54 예상)"

    dt_map, cls_map = load_exif_dt()
    missing_dt = [f for f in all_files if f not in dt_map]
    if missing_dt:
        raise RuntimeError(f"EXIF 없는 파일 {len(missing_dt)}개: {missing_dt[:5]}")

    old_pairs = adjacent_pairs(old_files, dt_map, cls_map)
    all_pairs_865 = adjacent_pairs(all_files, dt_map, cls_map)
    new_involved_pairs = [p for p in all_pairs_865 if p[0] in new_files or p[1] in new_files]

    print(f"\nOLD_PAIRS (811장만으로 재구성): {len(old_pairs)}쌍")
    print(f"ALL_PAIRS_865 (865장 전체): {len(all_pairs_865)}쌍")
    print(f"  그중 신규 파일이 관여한 쌍: {len(new_involved_pairs)}쌍")

    # (a) OLD_PAIRS x 811-CV
    n_a, f_a, m_a, d_a = flip_rate(old_pairs, probs_811)
    # (b) OLD_PAIRS x 865-CV
    n_b, f_b, m_b, d_b = flip_rate(old_pairs, probs_865)
    # (c) ALL_PAIRS_865 x 865-CV
    n_c, f_c, m_c, d_c = flip_rate(all_pairs_865, probs_865)
    # (d) 신규 파일 관여쌍만 x 865-CV (참고)
    n_d, f_d, m_d, d_d = flip_rate(new_involved_pairs, probs_865)

    def pct(f, n):
        return f"{f}/{n} = {100*f/n:.1f}%" if n else "n/a"

    print(f"\n(a) OLD_PAIRS x 811-CV (T72 재현 시도)      : 변동률 {pct(f_a, n_a)}  (누락 {m_a})")
    print(f"(b) OLD_PAIRS x 865-CV (같은 옛 장면, 새 모델) : 변동률 {pct(f_b, n_b)}  (누락 {m_b})")
    print(f"(c) 865 전체쌍 x 865-CV (T76 재현 시도)         : 변동률 {pct(f_c, n_c)}  (누락 {m_c})")
    print(f"(d) 신규파일 관여쌍만 x 865-CV (참고)            : 변동률 {pct(f_d, n_d)}  (누락 {m_d})")

    print("\n(a) 세부 전환:", dict(d_a))
    print("(b) 세부 전환:", dict(d_b))
    print("(c) 세부 전환:", dict(d_c))
    print("(d) 세부 전환:", dict(d_d))


if __name__ == "__main__":
    main()
