import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';

import 'angle_estimator.dart';
import 'frame_bench.dart';

/// T104: 노면 분할 모델 후보의 **실기기 속도 측정용** 러너. 안내에 쓰지 않는다.
///
/// 에셋 `bench_seg_t104.onnx`는 LR-ASPP MobileNetV3-Small, 입력 224, 출력
/// [1,5,224,224], **학습하지 않은 가중치**(`train/bench_seg_t104.py`,
/// seed 104)다 — 속도는 가중치와 무관하므로 측정에는 충분하다. 출력 값은
/// 의미가 없다.
///
/// 전처리는 위치 모델과 같은 `AngleEstimator.preprocessFrame(cropRatio: 1.0)`
/// (실제 분할 모델도 화면 전체를 볼 것이므로). 출력 읽기(`value`)는 약 25만
/// 개 값을 Dart 리스트로 옮기는 비용이라 실제 기능에도 드는 비용으로 보고 따로 잰다.
class SegBenchModel {
  static const _inputSize = 224;

  OrtSession? _session;

  bool get isReady => _session != null;

  /// OrtEnv는 다른 모델이 이미 init했다고 가정한다(카메라 화면 초기화 이후 호출).
  Future<void> init() async {
    if (_session != null) return;
    final raw = await rootBundle.load('assets/model/bench_seg_t104.onnx');
    _session = OrtSession.fromBuffer(raw.buffer.asUint8List(), OrtSessionOptions());
  }

  /// 한 프레임을 돌리고 전처리·추론·출력 읽기 시간을 [bench]에 기록한다.
  void runTimed(CameraImage image, int rotationDegrees, FrameBench bench) {
    final session = _session;
    if (session == null) return;

    final sw = Stopwatch()..start();
    final input =
        AngleEstimator.preprocessFrame(image, rotationDegrees, cropRatio: 1.0);
    bench.add('seg_pre', sw.elapsedMicroseconds / 1000);
    if (input == null) return;

    sw
      ..reset()
      ..start();
    final tensor = OrtValueTensor.createTensorWithDataList(
        input, [1, 3, _inputSize, _inputSize]);
    final runOptions = OrtRunOptions();
    final List<OrtValue?> outputs;
    try {
      outputs = session.run(runOptions, {'input': tensor});
    } finally {
      tensor.release();
      runOptions.release();
    }
    bench.add('seg_inf', sw.elapsedMicroseconds / 1000);
    if (outputs.isEmpty) return;

    sw
      ..reset()
      ..start();
    final out = outputs.first as OrtValueTensor;
    final value = out.value as List;
    out.release();
    bench.add('seg_out', sw.elapsedMicroseconds / 1000);
    assert(value.isNotEmpty);
  }

  void dispose() {
    _session?.release();
    _session = null;
  }
}
