import torch
import torch.nn as nn
from torchvision.models import mobilenet_v3_small, MobileNet_V3_Small_Weights

MODEL_PT   = r"C:\crossWalk\model\crosswalk_model.pt"
ONNX_OUT   = r"C:\crossWalk\model\crosswalk_model.onnx"
IMG_SIZE   = 224

model = mobilenet_v3_small(weights=MobileNet_V3_Small_Weights.DEFAULT)
in_features = model.classifier[3].in_features
model.classifier[3] = nn.Linear(in_features, 3)
model.load_state_dict(torch.load(MODEL_PT, map_location="cpu"))
model.eval()

dummy = torch.randn(1, 3, IMG_SIZE, IMG_SIZE)
torch.onnx.export(
    model, dummy, ONNX_OUT,
    input_names=["input"],
    output_names=["output"],
    dynamic_axes={"input": {0: "batch"}, "output": {0: "batch"}},
    opset_version=17,
)
print(f"ONNX 저장 완료: {ONNX_OUT}")
