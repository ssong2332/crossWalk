import hashlib
import json
from pathlib import Path
import torch
import torch.nn as nn
from torchvision.models import mobilenet_v3_small, MobileNet_V3_Small_Weights

# T54: 라벨 순서의 단일 출처는 train_model.py의 LABELS 하나뿐이다.
# 여기서 개수를 다시 적으면 두 곳이 갈라질 수 있으므로 import해서 쓴다.
from train_model import CLASS_DIRS, LABELS

REPO_ROOT = Path(__file__).resolve().parent.parent
MODEL_PT   = REPO_ROOT / "model" / "crosswalk_model.pt"
ONNX_OUT   = REPO_ROOT / "model" / "crosswalk_model.onnx"
LABELS_OUT = REPO_ROOT / "model" / "labels.json"
ASSET_DIR  = REPO_ROOT / "crosswalk_app" / "assets" / "model"
IMG_SIZE   = 224

# T42: 3-class(front/left/right) -> 4-class(front/left/right/none).
# T51: 4-class -> 5-class(none/approach/front/left/right).
# T54: 하드코딩 폐지 — train_model.LABELS에서 파생시킨다.
NUM_CLASSES = len(LABELS)

model = mobilenet_v3_small(weights=MobileNet_V3_Small_Weights.DEFAULT)
in_features = model.classifier[3].in_features
model.classifier[3] = nn.Linear(in_features, NUM_CLASSES)
model.load_state_dict(torch.load(MODEL_PT, map_location="cpu"))
model.eval()

dummy = torch.randn(1, 3, IMG_SIZE, IMG_SIZE)
# dynamo=False: 구형 TorchScript 기반 exporter 사용 → IR version 8 (모바일 호환)
torch.onnx.export(
    model, dummy, ONNX_OUT,
    input_names=["input"],
    output_names=["output"],
    opset_version=12,
    dynamo=False,
)
print(f"ONNX 저장 완료: {ONNX_OUT}")

# ── T54: 라벨 동기화 안전장치 ────────────────────────────────────────
# 이 프로젝트에서 세 번 터진 함정: 모델 출력 인덱스와 앱의 라벨 배열이
# 조용히 어긋나 "에러 없이 틀린 라벨"이 나온다(T42, T51, 그리고 T51 브랜치의
# 4-class 에셋 잔류). 익스포트한 모델 자신에게서 출력 개수를 읽어 검증하고,
# 라벨 순서 + 모델 해시를 labels.json에 함께 박아 앱 테스트가 대조하게 한다.
import onnx  # noqa: E402  (익스포트 이후에만 필요)

_m = onnx.load(str(ONNX_OUT), load_external_data=False)
_dims = [d.dim_value for d in _m.graph.output[0].type.tensor_type.shape.dim]
if _dims != [1, len(LABELS)]:
    raise RuntimeError(
        "익스포트된 모델의 출력 차원이 라벨 개수와 다름 — 중단.\n"
        f"  모델 출력 : {_dims}\n  기대       : [1, {len(LABELS)}]\n"
        f"  LABELS     : {LABELS}"
    )

_sha = hashlib.sha256(ONNX_OUT.read_bytes()).hexdigest()
_payload = {
    "labels": LABELS,          # 인덱스 순서 = 모델 출력 로짓 순서
    "class_dirs": CLASS_DIRS,  # 추적용: 이 폴더명 알파벳순이 곧 인덱스순
    "num_classes": len(LABELS),
    "model_sha256": _sha,      # 이 라벨이 설명하는 바로 그 모델 파일의 해시
}
_text = json.dumps(_payload, ensure_ascii=False, indent=2) + "\n"
LABELS_OUT.write_text(_text, encoding="utf-8")
print(f"labels.json 저장 완료: {LABELS_OUT}")

# 앱 에셋에도 같이 떨군다. onnx와 labels.json이 항상 한 쌍으로 움직여야
# 해시 대조가 의미를 갖는다.
if ASSET_DIR.is_dir():
    (ASSET_DIR / "labels.json").write_text(_text, encoding="utf-8")
    print(f"labels.json 저장 완료: {ASSET_DIR / 'labels.json'}")
    print("  ※ crosswalk_model.onnx는 자동 복사하지 않는다. 모델을 앱에 반영할 때")
    print("     직접 복사한 뒤 이 스크립트를 다시 돌리거나 labels.json을 함께 옮길 것.")

