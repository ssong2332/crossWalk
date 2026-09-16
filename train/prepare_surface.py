"""T94: AI Hub Surface Masking → image_extra/ (T92 규칙 자동 적용, 학습 전용).

입력: train/surface_zone_stats.csv (surface_zone_stats.py 산출, 크롭 내 crosswalk
      마스크 위치로 zone 판정). 변환은 prepare_aihub_none.py와 동일
      (중앙 810x1080 크롭 + 반시계 90도 회전 = 센서 방향).

내보내기 규칙:
  zone       -> 폴더                        상한(폴더=한 번의 보행, 연속 프레임)
  none       -> image_extra/0_none_surface        폴더당 5장 (균등 간격)
  none_far   -> image_extra/0_none_surface_far    폴더당 5장
  approach   -> image_extra/1_approach_surface    전부 (사용자 확인 대상)
  crossed    -> image_extra/5_crossed_surface     전부 (사용자 확인 대상, 학습 미사용)
  on         -> image_extra/on_surface_unlabeled  전부 (방향 없음 → 학습 미사용)
  그 외      -> 내보내지 않음
폴더명 접두사가 CLASS_DIRS와 같아야 groupkfold_cv/train_model이 클래스를 인식한다.
"""
import csv, os, sys
from collections import defaultdict
from pathlib import Path
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
STATS = REPO / "train" / "surface_zone_stats.csv"
OUT = REPO / "image_extra"
RULES = {  # zone: (폴더, 폴더당 상한 또는 None)
    "none": ("0_none_surface", 5),
    "none_far": ("0_none_surface_far", 5),
    "approach": ("1_approach_surface", None),
    "crossed": ("5_crossed_surface", None),
    "on": ("on_surface_unlabeled", None),
}
CW, CH = 810, 1080

def convert(src, dst):
    im = Image.open(src).convert("RGB")
    assert im.size == (1920, 1080), (src, im.size)
    x0 = (1920 - CW) // 2
    im = im.crop((x0, 0, x0 + CW, CH)).rotate(90, expand=True)
    dst.parent.mkdir(parents=True, exist_ok=True)
    im.save(dst, quality=92)

def main():
    rows = list(csv.DictReader(open(STATS, encoding="utf-8")))
    by = defaultdict(lambda: defaultdict(list))
    for r in rows:
        if r["zone"] in RULES:
            by[r["zone"]][os.path.dirname(r["file"])].append(r["file"])
    counts = {}
    for zone, (folder, cap) in RULES.items():
        n = 0
        for d, fs in sorted(by[zone].items()):
            fs = sorted(fs)
            if cap and len(fs) > cap:  # 균등 간격으로 골라 연속 프레임 중복을 줄인다
                fs = [fs[int(i * len(fs) / cap)] for i in range(cap)]
            for f in fs:
                name = "surf_" + os.path.basename(d) + "_" + Path(f).stem + ".jpg"
                convert(REPO / f, OUT / folder / name); n += 1
        counts[zone] = (folder, n)
    for z, (folder, n) in counts.items():
        print(f"{z:10} -> {folder:24} {n:5}장")

if __name__ == "__main__":
    sys.exit(main())
