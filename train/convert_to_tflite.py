"""
ONNX → TFLite 변환 스크립트
onnx2tf 설치 필요: pip install onnx2tf
Python 3.11/3.12 환경에서 더 안정적으로 동작합니다.

사용법:
  python convert_to_tflite.py
"""

import subprocess
import sys
import os

ONNX_PATH  = r"C:\crossWalk\model\crosswalk_model.onnx"
TFLITE_OUT = r"C:\crossWalk\model\tflite_out"
TFLITE_DST = r"C:\crossWalk\crosswalk_app\assets\model\crosswalk_model.tflite"


def try_onnx2tf():
    print("[방법 1] onnx2tf 사용...")
    try:
        import onnx2tf  # noqa: F401
    except ImportError:
        print("  onnx2tf 미설치. 설치 중...")
        subprocess.check_call([sys.executable, "-m", "pip", "install", "onnx2tf"])

    result = subprocess.run(
        [sys.executable, "-m", "onnx2tf",
         "-i", ONNX_PATH,
         "-o", TFLITE_OUT,
         "--output_integer_quantize_type", "INT8",
         "--non_verbose"],
        capture_output=True, text=True
    )
    if result.returncode == 0:
        # 생성된 tflite 파일 찾아서 복사
        import glob, shutil
        tflites = glob.glob(os.path.join(TFLITE_OUT, "**", "*.tflite"), recursive=True)
        if tflites:
            os.makedirs(os.path.dirname(TFLITE_DST), exist_ok=True)
            shutil.copy(tflites[0], TFLITE_DST)
            print(f"  [OK] TFLite 저장: {TFLITE_DST}")
            return True
    print(f"  [FAIL] 오류: {result.stderr[-500:]}")
    return False


def try_tensorflow_lite_converter():
    """TensorFlow가 설치된 경우 직접 변환"""
    print("[방법 2] tensorflow + tf2onnx 역방향 변환 시도...")
    try:
        import tensorflow as tf
        import onnx
        from onnx_tf.backend import prepare
        import shutil

        onnx_model = onnx.load(ONNX_PATH)
        tf_rep = prepare(onnx_model)
        saved_model_path = r"C:\crossWalk\model\saved_model"
        tf_rep.export_graph(saved_model_path)

        converter = tf.lite.TFLiteConverter.from_saved_model(saved_model_path)
        converter.optimizations = [tf.lite.Optimize.DEFAULT]
        tflite_model = converter.convert()

        os.makedirs(os.path.dirname(TFLITE_DST), exist_ok=True)
        with open(TFLITE_DST, "wb") as f:
            f.write(tflite_model)
        print(f"  [OK] TFLite 저장: {TFLITE_DST}")
        shutil.rmtree(saved_model_path, ignore_errors=True)
        return True
    except Exception as e:
        print(f"  [FAIL] {e}")
        return False


def manual_instructions():
    print("\n[대안] Google Colab에서 변환하기:")
    print("  1. crosswalk_model.onnx를 Google Drive에 업로드")
    print("  2. Colab에서 실행:")
    print("     !pip install onnx2tf")
    print("     !onnx2tf -i /content/drive/MyDrive/crosswalk_model.onnx -o /content/tflite_out")
    print("  3. 생성된 .tflite 파일을 다운로드 후")
    print(f"     {TFLITE_DST} 에 복사")


if __name__ == "__main__":
    if not os.path.exists(ONNX_PATH):
        print(f"[ERROR] ONNX 파일 없음: {ONNX_PATH}")
        print("먼저 train_model.py를 실행하여 ONNX 파일을 생성하세요.")
        sys.exit(1)

    if try_onnx2tf():
        print("\n변환 완료! 다음 단계: flutter run")
    elif try_tensorflow_lite_converter():
        print("\n변환 완료! 다음 단계: flutter run")
    else:
        manual_instructions()
