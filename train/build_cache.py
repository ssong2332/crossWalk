"""학습용 224x224 캐시 생성 — 원본 12MP JPEG 디코딩 비용을 없앤다.

배경 (2026-08-23 실측):
  `image/` 원본은 전부 4000x3000(12MP), 평균 4.8MB. torch는 CPU 전용 빌드
  (2.12.0+cpu, CUDA 불가), CPU 스레드 4개. 매 에폭마다 학습 456장을 12MP에서
  디코딩해 224로 줄이므로, MobileNetV3-small 자체보다 전처리가 더 비싸다.
  세션 단위 5-fold 한 번이 약 4.75시간(에폭당 2.9분)이었다.

결과가 바뀌지 않는 근거:
  TRAIN_TF/EVAL_TF의 첫 연산이 `transforms.Resize((224, 224))`로 **고정**이다
  (랜덤 크롭이 아니다). 증강(Flip/Rotation/ColorJitter)은 그 **이후**에 온다.
  따라서 Resize까지를 미리 계산해 두는 것은 수학적으로 동일한 입력을 준다.
  손실 압축으로 인한 미세 차이도 없애려고 JPEG가 아니라 **PNG(무손실)**로 저장한다.
  torchvision과 같은 연산을 쓰기 위해 직접 PIL.resize를 호출하지 않고
  `transforms.Resize`를 그대로 사용한다.

EXIF 주의:
  세션 분할은 원본의 EXIF DateTimeOriginal을 쓴다. 캐시는 **픽셀 전용**이며
  메타데이터 스캔과 근사중복 판정은 원본을 계속 사용한다. 그래야 지금까지의
  세션/중복 기준과 수치가 그대로 비교된다.

증분:
  캐시 파일이 원본보다 새것이면 건너뛴다. 이미지를 추가한 뒤 다시 돌리면
  **새 파일만** 처리한다.
"""
import sys
from pathlib import Path

from PIL import Image, ImageOps
from torchvision import transforms

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "image"
DST = REPO / "train" / "cache224"
IMG_SIZE = 224
RESIZE = transforms.Resize((IMG_SIZE, IMG_SIZE))


def cache_path(src: Path) -> Path:
    return DST / src.parent.name / (src.stem + ".png")


def build(verbose: bool = True) -> tuple[int, int]:
    """(새로 만든 수, 건너뛴 수)를 돌려준다."""
    made = skipped = 0
    srcs = sorted(SRC.rglob("*.jpg"))
    for i, s in enumerate(srcs, 1):
        d = cache_path(s)
        if d.exists() and d.stat().st_mtime >= s.stat().st_mtime:
            skipped += 1
            continue
        d.parent.mkdir(parents=True, exist_ok=True)
        # exif_transpose를 **일부러 적용하지 않는다.**
        # `ListDataset.__getitem__`이 `Image.open(path).convert("RGB")`만 하므로
        # 학습 경로는 EXIF Orientation을 무시한다(실측: 637장 중 625장이
        # Orientation=6, 즉 표시용으로는 90도 회전이 필요한 사진이다).
        # 여기서 회전을 적용하면 캐시가 지금까지의 모든 측정치와 다른 입력을
        # 주게 되어 비교가 깨진다. 회전 정책 자체의 타당성은 T56에서 다룬다.
        im = Image.open(s).convert("RGB")
        RESIZE(im).save(d, format="PNG", optimize=False)
        made += 1
        if verbose and made % 50 == 0:
            print(f"  {i}/{len(srcs)} 진행 (신규 {made})", flush=True)

    # 원본이 사라진 캐시는 지운다 (라벨 폴더 이동/삭제 추적)
    live = {cache_path(s) for s in srcs}
    stale = [p for p in DST.rglob("*.png") if p not in live]
    for p in stale:
        p.unlink()
    if verbose:
        print(f"캐시 완료: 신규 {made} / 유지 {skipped} / 정리 {len(stale)} -> {DST}")
    return made, skipped


if __name__ == "__main__":
    build()
    if "--verify" in sys.argv:
        # 원본 경로와 캐시 경로가 같은 텐서를 내는지 실제로 대조한다.
        import torch
        tf = transforms.Compose([RESIZE, transforms.ToTensor()])
        worst = 0.0
        for s in sorted(SRC.rglob("*.jpg"))[:20]:
            a = tf(Image.open(s).convert("RGB"))  # ListDataset와 동일 경로
            b = tf(Image.open(cache_path(s)).convert("RGB"))
            worst = max(worst, (a - b).abs().max().item())
        print(f"[검증] 표본 20장 최대 픽셀 차이: {worst:.8f}  (0이면 완전 동일)")
