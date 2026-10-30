"""T159: 판정표를 통과한 점수(순서형|각|·회귀부호, 반전 TTA)를 ONNX 하나로 내보낸다.

앱이 원본·반전 ONNX 출력을 따로 평균하면 CV 점수와 달라진다(1,331장 중 194장, T150 판정 미달).
그래서 반전을 그래프 안에서 한다: 입력 [1,3,224,224] → 원본·좌우반전 2장을 한 번에 → 
  reg = (reg_원본 − reg_반전)/2,  |각| = (ord_원본 + ord_반전)/2,  출력 = sign(reg)·|각| / 90  ([1,1]).
CV 계산(`t159_report.from_t159(.., "ord_reg_tta")`)과 같은 식이다.

    python train/t159_export_tta.py fullbw224   # model/t159/<이름>.pt → model/t159/<이름>_ord_reg_tta.onnx
"""
import hashlib
import sys
from pathlib import Path

import torch
from torch import nn

sys.path.insert(0, str(Path(__file__).resolve().parent))
import t159_train as tt  # noqa: E402
import train_angle as ta  # noqa: E402


class ExportTTA(nn.Module):
    def __init__(self, head):
        super().__init__()
        self.head = head

    def forward(self, x):
        o = self.head(torch.cat([x, torch.flip(x, dims=[3])], 0))
        reg = (o[0:1, 0:1] - o[1:2, 0:1]) / 2
        k = len(tt.CUTS)
        oa = (tt.ord_abs(torch.sigmoid(o[0:1, 1:1 + k])) + tt.ord_abs(torch.sigmoid(o[1:2, 1:1 + k]))) / 2
        return torch.sign(reg) * oa[:, None] / ta.ANGLE_SCALE


def main(name, img=224):
    head = tt.Head(img)
    head.load_state_dict(torch.load(tt.MODEL_DIR / f"{name}.pt", map_location="cpu"))
    head.eval()
    p = tt.MODEL_DIR / f"{name}_ord_reg_tta.onnx"
    torch.onnx.export(ExportTTA(head), torch.randn(1, 3, img, img), p, input_names=["input"],
                      output_names=["output"], opset_version=12, dynamo=False)
    import onnx
    m = onnx.load(str(p))
    shp = [d.dim_value for d in m.graph.output[0].type.tensor_type.shape.dim]
    assert m.ir_version <= 8 and shp == [1, 1], (m.ir_version, shp)
    print(f"ONNX {p} ir={m.ir_version} opset={m.opset_import[0].version} out={shp} "
          f"sha256 {hashlib.sha256(p.read_bytes()).hexdigest()}")


if __name__ == "__main__":
    main(sys.argv[1])
