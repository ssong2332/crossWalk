"""T104: 노면 분할 모델 후보의 추론 비용을 **현재 앱 모델과 같은 조건**에서 잰다.

폰 실측이 아니다 — 이 PC CPU에서 ONNX Runtime으로 잰 **상대 비용**이다. 현재 앱의
분류기는 실기기에서 5프레임마다 돌고 있으므로, 후보가 분류기의 몇 배인지로 폰 비용을
추정한다(추정: 폰/PC 비율이 모델 간에 같다고 가정).

측정 조건: onnxruntime CPU, 스레드 1개와 4개, 워밍업 20회 후 200회의 중앙값(ms).
후보는 가중치 없이(weights=None) 구조만 만든다 — 속도는 가중치와 무관하다.
출력 클래스 수는 노면 5종(배경/인도/차도/점자블록 선형/점자블록 점형)을 가정.

실행: python train/bench_seg_t104.py
"""
import os
import statistics
import tempfile
import time

import numpy as np
import onnxruntime as ort
import torch
from torchvision.models import mobilenet_v3_large, mobilenet_v3_small
from torchvision.models.segmentation import (deeplabv3_mobilenet_v3_large,
                                             lraspp_mobilenet_v3_large)
from torchvision.models.segmentation.lraspp import LRASPPHead

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(REPO, "crosswalk_app", "assets", "model")
N_CLS = 5


class LRASPPSmall(torch.nn.Module):
    """MobileNetV3-Small 백본 + LR-ASPP 헤드(torchvision엔 Small 버전이 없어 조립)."""

    def __init__(self, n_cls):
        super().__init__()
        f = mobilenet_v3_small(weights=None).features
        self.low = f[:4]    # stride 8, 24ch
        self.high = f[4:]   # stride 32, 576ch
        self.head = LRASPPHead(24, 576, n_cls, 128)

    def forward(self, x):
        low = self.low(x)
        out = self.head({"low": low, "high": self.high(low)})
        return torch.nn.functional.interpolate(out, size=x.shape[-2:], mode="bilinear",
                                               align_corners=False)


class OutOnly(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, x):
        return self.m(x)["out"]


def export(model, size, path):
    model.eval()
    torch.onnx.export(model, torch.randn(1, 3, *size), path, input_names=["input"],
                      output_names=["output"], opset_version=12, dynamo=False)


def bench(path, size, threads):
    so = ort.SessionOptions()
    so.intra_op_num_threads = threads
    so.inter_op_num_threads = 1
    s = ort.InferenceSession(path, so, providers=["CPUExecutionProvider"])
    name = s.get_inputs()[0].name
    x = np.random.rand(1, 3, *size).astype(np.float32)
    for _ in range(20):
        s.run(None, {name: x})
    t = []
    for _ in range(200):
        a = time.perf_counter()
        s.run(None, {name: x})
        t.append((time.perf_counter() - a) * 1000)
    return statistics.median(t)


def params(m):
    return sum(p.numel() for p in m.parameters()) / 1e6


def main():
    torch.set_num_threads(1)
    tmp = tempfile.mkdtemp()
    rows = []
    # 현재 앱 모델(배포 파일 그대로)
    for f, size in [("crosswalk_model.onnx", (224, 224)),
                    ("crosswalk_angle.onnx", (224, 224)),
                    ("crosswalk_position.onnx", (224, 224))]:
        rows.append(("앱: " + f, os.path.join(ASSETS, f), size, None))
    cands = [
        ("후보: LR-ASPP MobileNetV3-Small", lambda: LRASPPSmall(N_CLS)),
        ("후보: LR-ASPP MobileNetV3-Large",
         lambda: OutOnly(lraspp_mobilenet_v3_large(weights=None, weights_backbone=None,
                                                   num_classes=N_CLS))),
        ("후보: DeepLabV3 MobileNetV3-Large",
         lambda: OutOnly(deeplabv3_mobilenet_v3_large(weights=None, weights_backbone=None,
                                                      num_classes=N_CLS, aux_loss=False))),
    ]
    for name, mk in cands:
        m = mk()
        for size in [(224, 224), (320, 320)]:
            p = os.path.join(tmp, f"{abs(hash((name, size)))}.onnx")
            export(m, size, p)
            rows.append((f"{name} {size[0]}", p, size, params(m)))
    base = {}
    print(f"{'모델':45s} {'입력':>7s} {'파라미터(M)':>11s} {'파일(MB)':>8s} {'1스레드 ms':>10s} {'4스레드 ms':>10s} {'분류기 대비(1스레드)':>18s}")
    for name, path, size, prm in rows:
        t1, t4 = bench(path, size, 1), bench(path, size, 4)
        if "crosswalk_model" in name:
            base["t1"] = t1
        mb = os.path.getsize(path) / 1e6
        prm_s = f"{prm:.2f}" if prm is not None else "-"
        print(f"{name:45s} {size[0]:>7d} {prm_s:>11s} {mb:>8.1f} {t1:>10.1f} {t4:>10.1f} {t1 / base['t1']:>17.2f}x")


if __name__ == "__main__":
    main()
