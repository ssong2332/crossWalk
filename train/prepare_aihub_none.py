"""T90: AI Hub 인도보행 샘플 -> 분류기 **학습 전용** none 이미지 생성.

`label_aihub_none.py`로 매긴 `aihub_none_labels.csv`를 읽어
  label == none            -> image_extra/0_none_aihub/
  label == none_cw_visible -> image_extra/0_none_aihub_cw/   (옆·건너편 횡단보도)
로 저장한다. approach·skipped는 만들지 않는다(이번 실험은 none 보강만).

입력 형식을 배포 앱·기존 학습과 맞추는 변환 (중요):
  기존 학습 사진은 4000x3000 **센서 방향**(EXIF Orientation=6, 표시하려면 90도
  시계방향 회전 필요)이고, build_cache.py:53은 일부러 EXIF를 적용하지 않는다.
  즉 모델은 "세로 화면을 반시계 90도 돌린 가로 버퍼"를 본다. AI Hub 사진은
  1920x1080 가로 정방향이므로 그대로 넣으면 방향이 다르다. 그래서
    1) 중앙 세로 크롭 810x1080 (폰 표시 화면 3:4와 같은 비율)
    2) 반시계 90도 회전 -> 1080x810 (센서 버퍼처럼)
  으로 저장한다. 224 축소는 학습 transform(Resize)이 한다.

주의: 이 폴더는 `image/` 밖이라 build_cache가 건드리지 않고, groupkfold_cv.py는
  EXTRA_TRAIN_DIRS로 받아 **모든 fold의 train에만** 넣는다(val/test 제외).
  AI Hub 사진은 EXIF 촬영시각이 없어 세션 분할을 못 하지만, 평가에 안 쓰므로
  누수 문제가 없다.

실행:
    python train/prepare_aihub_none.py [샘플 폴더]
"""
import csv
import os
import sys
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parent.parent
DEFAULT_SRC = r"C:\Users\박수홍\Downloads\2019-01-004.인도보행영상_sample"
LABELS = REPO / "train" / "aihub_none_labels.csv"
OUT = {
    "none": REPO / "image_extra" / "0_none_aihub",
    "none_cw_visible": REPO / "image_extra" / "0_none_aihub_cw",
}
CROP_W, CROP_H = 810, 1080  # 3:4


def convert(src: Path, dst: Path):
    im = Image.open(src).convert("RGB")
    w, h = im.size
    if (w, h) != (1920, 1080):
        raise RuntimeError(f"예상 밖 해상도 {im.size}: {src}")
    x0 = (w - CROP_W) // 2
    im = im.crop((x0, 0, x0 + CROP_W, CROP_H))
    im = im.rotate(90, expand=True)  # 반시계 90도 -> 1080x810
    assert im.size == (1080, 810), im.size
    dst.parent.mkdir(parents=True, exist_ok=True)
    im.save(dst, quality=92)


def main():
    src = Path(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SRC)
    counts = {k: 0 for k in OUT}
    with open(LABELS, encoding="utf-8") as f:
        for r in csv.DictReader(f):
            if r["status"] != "ok" or r["label"] not in OUT:
                continue
            rel = r["file"]
            dst = OUT[r["label"]] / ("aihub_" + rel.replace("/", "_").rsplit(".", 1)[0] + ".jpg")
            convert(src / rel, dst)
            counts[r["label"]] += 1
    for k, v in counts.items():
        print(f"{k:16} {v:4}장 -> {OUT[k]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
