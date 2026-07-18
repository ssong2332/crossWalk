"""
T1/T42: 배포된 모델(model/crosswalk_model.onnx)의 실측 정확도 평가.

앱의 실제 추론 경로(crosswalk_app/lib/services/classifier.dart)를 최대한 그대로 재현한다:
- ONNX Runtime으로 추론 (PyTorch 아님)
- 224x224 리사이즈
- ImageNet 정규화 (mean=[0.485,0.456,0.406], std=[0.229,0.224,0.225])
- NCHW 입력 텐서
- softmax(logits) -> 확률
- 클래스별 임계값 판정: front=0.65, left/right=0.55, none=0.50
  (T42 통합 완료 시점 기준 `crosswalk_app/lib/services/classifier.dart`의 실제 값과
  동일 — front가 0.85→0.65로 내려간 이유: 4-클래스로 늘면서 softmax 확률이 분산되어
  3-클래스 때의 임계값이 지나치게 엄격해졌음을 이 스크립트로 직접 진단한 뒤 반영한 값.
  아래 EVAL_*_THRESHOLD 환경변수로 다른 값을 일회성으로 시험해볼 수 있다.)
- 스무딩(최근 5프레임 평균)은 미적용 (단일 이미지 프레임별 단발 추론이므로 해당 없음)

T42 참고: classifier.dart는 이제 4-class(front/left/none/right)를 알고 있으며
(docs/Tasks.md T42), 이 평가 스크립트의 기본 임계값도 그 실제 값과 동기화되어 있다.

순수 평가 스크립트. 모델을 재학습하거나 수정하지 않는다.
"""
import io
import os
import sys
from pathlib import Path

import numpy as np
import onnxruntime as ort
from PIL import Image

REPO_ROOT = Path(__file__).resolve().parent.parent
MODEL_PATH = REPO_ROOT / "model" / "crosswalk_model.onnx"
TEST_DIR = REPO_ROOT / "train" / "data_prepared" / "test"

# T42: "none"(횡단보도 없음) 클래스 추가.
# 주의(정확성 필수): torchvision ImageFolder는 하위 폴더명을 알파벳순으로 정렬해
# class_to_idx를 부여하므로(train_model.py get_loaders()), 실제 모델 출력(logits)의
# 인덱스 순서는 front(0), left(1), none(2), right(3)이다. 이 리스트는 반드시 그
# 순서와 정확히 일치해야 한다 — front/left/right/none처럼 "보기 편한" 순서로 바꾸면
# 로짓을 잘못된 라벨에 매핑하는 조용한 버그가 된다.
LABELS = ["front", "left", "none", "right"]
IMG_SIZE = 224
MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)

# T42 완료: 아래 세 값은 더 이상 잠정값이 아니라 `classifier.dart`에 실제로
# 반영되어 있는 값과 동일하다(이 스크립트의 진단 결과를 근거로 확정됨). 값을 바꾸려면
# classifier.dart도 함께 갱신해야 한다 — 이 파일만 고치면 평가 결과가 앱의 실제
# 동작과 다시 어긋난다(reviewer가 지적한 문제, docs/Tasks.md T42 참고).
FRONT_THRESHOLD = 0.65
DEVIATION_THRESHOLD = 0.55  # left/right
NONE_THRESHOLD_PLACEHOLDER = 0.50

# 일회성 진단용 환경변수 오버라이드. 기본값(위 세 상수, 곧 앱의 실제 임계값)은 그대로
# 유지되고, 아래처럼 환경변수를 지정했을 때만 이번 실행 한정으로 다른 값을 시험할 수
# 있다 — 예: 향후 재학습 후 임계값을 다시 진단하고 싶을 때.
FRONT_THRESHOLD = float(os.environ.get("EVAL_FRONT_THRESHOLD", FRONT_THRESHOLD))
DEVIATION_THRESHOLD = float(os.environ.get("EVAL_DEVIATION_THRESHOLD", DEVIATION_THRESHOLD))
NONE_THRESHOLD_PLACEHOLDER = float(
    os.environ.get("EVAL_NONE_THRESHOLD", NONE_THRESHOLD_PLACEHOLDER)
)


def preprocess(image_path: Path) -> np.ndarray:
    """앱의 _preprocessCamera와 동일한 전처리: RGB 변환 -> 224x224 리사이즈 -> ImageNet 정규화 -> NCHW."""
    # classifier.dart의 img.copyResize()는 interpolation 인자를 지정하지 않아
    # image 패키지(v4.8.0, copy_resize.dart:23)의 기본값인 Interpolation.nearest를 사용한다.
    # PIL의 NEAREST로 이를 재현해 앱의 실제 추론 경로와 일치시킨다.
    img = Image.open(image_path).convert("RGB")
    img = img.resize((IMG_SIZE, IMG_SIZE), Image.NEAREST)
    arr = np.asarray(img, dtype=np.float32) / 255.0  # HWC, RGB, [0,1]
    arr = (arr - MEAN) / STD
    arr = arr.transpose(2, 0, 1)  # HWC -> CHW
    arr = np.expand_dims(arr, axis=0)  # NCHW
    return arr.astype(np.float32)


def softmax(logits: np.ndarray) -> np.ndarray:
    max_logit = np.max(logits)
    exps = np.exp(logits - max_logit)
    return exps / np.sum(exps)


def decide(probs: np.ndarray) -> str | None:
    """앱의 decideFromLogits와 동일한 임계값 판정 로직 (스무딩 제외, 단일 프레임)."""
    best_idx = int(np.argmax(probs))
    label = LABELS[best_idx]
    conf = probs[best_idx]
    if label == "front":
        threshold = FRONT_THRESHOLD
    elif label == "none":
        threshold = NONE_THRESHOLD_PLACEHOLDER
    else:
        threshold = DEVIATION_THRESHOLD
    if conf < threshold:
        return None  # 임계값 미달 -> 판정 없음 (앱에서는 경고 없음)
    return label


def main():
    session = ort.InferenceSession(str(MODEL_PATH))
    input_name = session.get_inputs()[0].name

    # true_label -> predicted_label(or None) 목록
    results: dict[str, list[str | None]] = {label: [] for label in LABELS}
    file_counts: dict[str, int] = {}

    for true_label in LABELS:
        class_dir = TEST_DIR / true_label
        files = sorted(
            p for p in class_dir.iterdir()
            if p.is_file() and p.suffix.lower() in (".jpg", ".jpeg", ".png", ".bmp")
        )
        file_counts[true_label] = len(files)
        for f in files:
            input_tensor = preprocess(f)
            outputs = session.run(None, {input_name: input_tensor})
            logits = outputs[0][0]  # [1,4] -> [4] (T42: front/left/right/none)
            probs = softmax(logits)
            pred = decide(probs)
            results[true_label].append(pred)

    # confusion matrix: rows = true label, cols = predicted label (+ "None"/미판정)
    pred_cols = LABELS + [None]
    print("=" * 70)
    print("T1/T42 모델 정확도 실측 결과 (4-class: front/left/right/none, model/crosswalk_model.onnx)")
    print("=" * 70)
    print(f"\n표본 크기: front={file_counts['front']}, left={file_counts['left']}, "
          f"right={file_counts['right']}, none={file_counts['none']}\n")

    print("Confusion Matrix (행=실제 라벨, 열=예측 라벨, None=임계값 미달/무판정)")
    header = "true\\pred".ljust(12) + "".join(str(c).ljust(10) for c in pred_cols)
    print(header)
    matrix: dict[str, dict] = {}
    for true_label in LABELS:
        row = {}
        for c in pred_cols:
            row[c] = sum(1 for p in results[true_label] if p == c)
        matrix[true_label] = row
        line = true_label.ljust(12) + "".join(str(row[c]).ljust(10) for c in pred_cols)
        print(line)

    print()
    print("클래스별 Recall / Precision")
    print("-" * 70)
    total_true_positive = {}
    total_predicted_as = {label: 0 for label in LABELS}
    for true_label in LABELS:
        for c in pred_cols:
            if c in LABELS:
                total_predicted_as[c] += matrix[true_label][c]

    target_met = {}
    for label in LABELS:
        n_total = file_counts[label]
        tp = matrix[label][label]
        recall = tp / n_total if n_total > 0 else float("nan")
        predicted_total = total_predicted_as[label]
        precision = matrix[label][label] / predicted_total if predicted_total > 0 else float("nan")
        miss = n_total - tp
        print(f"{label}: recall={recall:.3f} ({tp}/{n_total}), precision={precision:.3f} ({tp}/{predicted_total}), miss={miss}")
        if label in ("left", "right"):
            target_met[label] = recall >= 0.90

    print()
    print("=" * 70)
    print("목표 판정: left/right recall >= 90% (miss rate <= 10%)")
    print("=" * 70)
    for label in ("left", "right"):
        n = file_counts[label]
        tp = matrix[label][label]
        recall = tp / n if n > 0 else float("nan")
        status = "충족" if target_met[label] else "미충족"
        print(f"  {label}: {tp}/{n} 정탐 (recall={recall*100:.1f}%) -> {status}")
        if n < 30:
            print(f"    [경고] 표본 크기 n={n}로 매우 작음 - 통계적 신뢰도 낮음. "
                  f"이미지 1~2개의 판정 변화만으로도 recall이 크게 흔들릴 수 있음.")

    print()
    print("클래스별 개별 판정 원자료 (파일명 -> 예측):")
    for true_label in LABELS:
        class_dir = TEST_DIR / true_label
        files = sorted(
            p for p in class_dir.iterdir()
            if p.is_file() and p.suffix.lower() in (".jpg", ".jpeg", ".png", ".bmp")
        )
        print(f"\n  [{true_label}] (n={len(files)})")
        for f, pred in zip(files, results[true_label]):
            mark = "OK" if pred == true_label else "MISS"
            print(f"    {f.name}: pred={pred} [{mark}]")


if __name__ == "__main__":
    # Windows 콘솔(cp949)에서도 한글/기호가 깨지지 않도록 UTF-8로 강제
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")
    main()
