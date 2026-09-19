"""T98: 배포용 좌우 위치 회귀 모델 학습 + ONNX 내보내기.

`train_position.py`는 **성능 측정용**(누수 없는 5-fold CV)이라 저장 가중치가
배포용이 아니다. 이 스크립트는 라벨 전량(자체 + Surface 학습 전용)으로 한 번
더 학습해 배포 모델을 만든다. `train_angle_final.py`와 같은 구조.

성능은 CV로 이미 측정됐다: train/position_cv_t98b.log (횡단보도 위 사진만 블록).

앱 통합 주의:
  - 입력은 EXIF 보정된 **화면(세로) 방향**, **중앙 크롭 없이** 화면 전체를
    224x224로 (각도 모델과 다르다 — 가장자리 단서를 살리기 위해).
  - 출력 x POS_SCALE(2.0) = 위치 단계(-2 왼쪽 끝 ~ +2 오른쪽 끝).
    앱의 `PositionEstimator.positionScale`과 같아야 한다.

실행:
    python train/train_position_final.py
"""

import hashlib
import json
import shutil
from pathlib import Path

import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import DataLoader

from train_position import (
    BATCH_SIZE, EPOCHS_FINETUNE, EPOCHS_FROZEN, IMG_SIZE, LR_FINETUNE, LR_FROZEN,
    POS_SCALE, PositionDataset, build_cache, build_model, load_items, run_epoch,
)

REPO = Path(__file__).resolve().parent.parent
PT_OUT = REPO / "model" / "crosswalk_position_final.pt"
ONNX_OUT = REPO / "model" / "crosswalk_position.onnx"
META_OUT = REPO / "model" / "position_meta.json"
ASSET_DIR = REPO / "crosswalk_app" / "assets" / "model"


def main():
    items = load_items()
    print(f"위치 라벨 {len(items)}장 전량으로 배포 모델 학습")
    build_cache(items)

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model = build_model().to(device)
    loader = DataLoader(PositionDataset(items, train=True),
                        batch_size=BATCH_SIZE, shuffle=True, num_workers=0)
    criterion = nn.SmoothL1Loss(beta=0.2)

    for p in model.features.parameters():
        p.requires_grad = False
    opt = optim.Adam(filter(lambda p: p.requires_grad, model.parameters()), lr=LR_FROZEN)
    for e in range(EPOCHS_FROZEN):
        print(f"  frozen  {e + 1}/{EPOCHS_FROZEN} "
              f"loss {run_epoch(model, loader, device, criterion, opt):.4f}", flush=True)

    for p in model.parameters():
        p.requires_grad = True
    opt = optim.Adam(model.parameters(), lr=LR_FINETUNE)
    sched = optim.lr_scheduler.CosineAnnealingLR(opt, T_max=EPOCHS_FINETUNE)
    for e in range(EPOCHS_FINETUNE):
        loss = run_epoch(model, loader, device, criterion, opt)
        sched.step()
        print(f"  finetune {e + 1}/{EPOCHS_FINETUNE} loss {loss:.4f}", flush=True)

    PT_OUT.parent.mkdir(parents=True, exist_ok=True)
    torch.save(model.state_dict(), PT_OUT)
    print(f"가중치 저장: {PT_OUT}")

    # T43/T1의 함정: 신형 exporter는 IR10/opset18로 내보내 모바일에서 못 읽는다.
    model.eval().cpu()
    dummy = torch.randn(1, 3, IMG_SIZE, IMG_SIZE)
    torch.onnx.export(
        model, dummy, ONNX_OUT,
        input_names=["input"], output_names=["output"],
        opset_version=12, dynamo=False,
    )
    print(f"ONNX 저장: {ONNX_OUT}")

    import onnx
    m = onnx.load(str(ONNX_OUT))
    out_shape = [d.dim_value for d in m.graph.output[0].type.tensor_type.shape.dim]
    print(f"  검증: ir_version={m.ir_version}, opset={m.opset_import[0].version}, output dims={out_shape}")
    assert m.ir_version <= 8, f"IR {m.ir_version} — 모바일 비호환"
    assert out_shape[-1] == 1, f"출력 차원이 1이 아님: {out_shape}"

    digest = hashlib.sha256(ONNX_OUT.read_bytes()).hexdigest()
    META_OUT.write_text(json.dumps({
        "position_scale": POS_SCALE,
        "img_size": IMG_SIZE,
        "input": "display_portrait_exif_corrected, full frame (no center crop)",
        "output": "lateral position in label units (-2 left edge .. +2 right edge) after x position_scale",
        "sha256": digest,
        "n_train": len(items),
        "cv_log": "train/position_cv_t98b.log",
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"메타 저장: {META_OUT}  (sha256 {digest[:16]}...)")

    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ONNX_OUT, ASSET_DIR / "crosswalk_position.onnx")
    (ASSET_DIR / "crosswalk_position.onnx.sha256").write_text(digest + "\n", encoding="utf-8")
    print(f"에셋 복사: {ASSET_DIR / 'crosswalk_position.onnx'} (+ .sha256)")


if __name__ == "__main__":
    main()
