"""T69: 배포용 각도 회귀 모델 학습 + ONNX 내보내기.

`train_angle.py`는 **성능 측정용**(누수 없는 5-fold 교차검증)이며, 저장되는
가중치는 마지막 fold 학습분이라 배포용이 아니다. 이 스크립트는 라벨 **전량**으로
한 번 더 학습해 배포 모델을 만든다.

교차검증으로 이미 측정된 성능(정직하게 병기):
    전체 405장   평균 13.4도 / 중앙 7.5도 / ±15도내 67%
    2_front      평균  4.1도 / ±10도내 95%
    1_approach   평균 10.5도
    4_right      평균 17.4도
    3_left       평균 24.5도
    방향(부호) 정확도 left 98% / right 98%
비교: 기존 고전 CV 34.5도, "항상 0도" 32.4도.

알려진 한계 — 큰 각도를 과소평가한다:
    회귀직선 기울기 0.709 (1.0이 이상적). ±60도를 넘는 정답에서는 축소율
    0.57~0.66으로 평균 24~31도 오차. **이는 고칠 수 있는 편향이 아니다** —
    선형 역보정을 실측해본 결과 오히려 악화됐다(13.4 -> 15.8도). 확신이 없을
    때 중앙으로 예측하는 것이 오차 최소화의 최적 반응이며, 억지로 늘리면
    잡음까지 증폭된다. 근본 해결은 큰 각도 라벨 데이터 보강이다.
    실패 양상 자체는 안전한 쪽이다: 방향은 98% 맞고 크기만 보수적으로 나온다.

EXIF 주의(중요):
    라벨과 학습은 `exif_transpose`로 보정한 **화면(세로) 방향** 기준이다.
    앱에서 이 모델에 프레임을 넣을 때도 **화면 방향으로 회전**해야 한다.
    회전 없이 넣으면 약 90도 계통 오차가 난다(검증 가능한 예측).
    기존 분류기는 EXIF 보정을 하지 않으므로 두 모델의 입력 방향이 다르다.

실행:
    python train/train_angle_final.py
"""

import hashlib
import json
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import DataLoader

from train_angle import (
    ANGLE_SCALE, BATCH_SIZE, EPOCHS_FINETUNE, EPOCHS_FROZEN, IMG_SIZE,
    LR_FINETUNE, LR_FROZEN, AngleDataset, build_cache, build_model,
    load_labeled_items, run_epoch,
)

REPO = Path(__file__).resolve().parent.parent
PT_OUT = REPO / "model" / "crosswalk_angle_final.pt"
ONNX_OUT = REPO / "model" / "crosswalk_angle.onnx"
META_OUT = REPO / "model" / "angle_meta.json"
ASSET_DIR = REPO / "crosswalk_app" / "assets" / "model"


def main():
    items = load_labeled_items()
    print(f"라벨 {len(items)}장 전량으로 배포 모델 학습")
    build_cache(items)

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model = build_model().to(device)
    loader = DataLoader(AngleDataset(items, train=True),
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

    # ── ONNX 내보내기 ────────────────────────────────────────────────
    # T43/T1의 함정: 신형 exporter는 IR10/opset18로 내보내 모바일에서 못 읽는다.
    # export_onnx.py와 동일하게 dynamo=False + opset 12를 쓴다.
    model.eval().cpu()
    dummy = torch.randn(1, 3, IMG_SIZE, IMG_SIZE)
    torch.onnx.export(
        model, dummy, ONNX_OUT,
        input_names=["input"], output_names=["output"],
        opset_version=12, dynamo=False,
    )
    print(f"ONNX 저장: {ONNX_OUT}")

    # 내보낸 파일을 **직접 열어** 규격을 검증한다(에셋이 조용히 어긋난 전례가 있다).
    import onnx
    m = onnx.load(str(ONNX_OUT))
    out_shape = [d.dim_value for d in
                 m.graph.output[0].type.tensor_type.shape.dim]
    print(f"  검증: ir_version={m.ir_version}, "
          f"opset={m.opset_import[0].version}, output dims={out_shape}")
    assert m.ir_version <= 8, f"IR {m.ir_version} — 모바일 비호환"
    assert out_shape[-1] == 1, f"출력 차원이 1이 아님: {out_shape}"

    digest = hashlib.sha256(ONNX_OUT.read_bytes()).hexdigest()
    META_OUT.write_text(json.dumps({
        "angle_scale": ANGLE_SCALE,
        "img_size": IMG_SIZE,
        "input_orientation": "display_portrait_exif_corrected",
        "output": "walking_direction_degrees (screen-up=0, clockwise+)",
        "sha256": digest,
        "cv_mean_abs_err_deg": 13.4,
        "cv_median_abs_err_deg": 7.5,
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"메타 저장: {META_OUT}  (sha256 {digest[:16]}...)")
    print("\n앱 통합 시 주의: 이 모델에는 **화면 방향으로 회전된** 프레임을 넣어야 한다.")


if __name__ == "__main__":
    main()
