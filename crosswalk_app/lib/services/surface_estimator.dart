import 'package:camera/camera.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';

import 'angle_estimator.dart';
import 'surface_guide.dart';

/// T104: 노면 분할 모델(점자블록 선형/점형·인도·차도·횡단보도) 러너.
///
/// 모델: LR-ASPP MobileNetV3-Small, 입력 [1,3,224,224], 출력 로짓 [1,6,224,224]
/// (`train/train_seg_t104.py`, test mIoU 0.704 — `docs/Tasks.md` T104 (10)).
/// 입력은 위치 모델과 같이 화면(세로) 방향 전체를 224로 누른다
/// (`AngleEstimator.preprocessFrame(cropRatio: 1.0)`) — 학습도 세로 3:4 영역을
/// 224로 눌러서 했다.
///
/// 비용(갤럭시 S25 울트라 실측, 같은 구조·학습 전 가중치): 전처리 44~48ms +
/// 추론 20ms + 출력 읽기 31~32ms. 출력 읽기(`value`)는 약 30만 개 값을 Dart
/// 리스트로 옮기는 비용이라 최적화 후보다(T104 NOT DONE).
class SurfaceEstimator {
  static const _inputSize = 224;
  static const assetPath = 'assets/model/crosswalk_surface.onnx';

  OrtSession? _session;

  bool get isReady => _session != null;

  /// OrtEnv는 분류기·각도·위치 모델이 이미 init했다고 가정한다(카메라 화면 초기화 이후 호출).
  Future<void> init() async {
    if (_session != null) return;
    final raw = await rootBundle.load(assetPath);
    final bytes = raw.buffer.asUint8List();
    await _verifyIntegrity(bytes);
    _session = OrtSession.fromBuffer(bytes, OrtSessionOptions());
  }

  Future<void> _verifyIntegrity(Uint8List modelBytes) async {
    try {
      final expected = (await rootBundle.loadString('$assetPath.sha256')).trim();
      if (expected.length == 64 &&
          sha256.convert(modelBytes).toString() != expected) {
        throw StateError('노면 모델 파일이 손상되었거나 변조되었습니다.');
      }
    } on StateError {
      rethrow;
    } catch (_) {
      // 해시 파일 없음 → 개발 환경, 건너뜀 (PositionEstimator와 같은 정책)
    }
  }

  /// 한 프레임의 노면 특징(아래 절반 3칸의 클래스 비율). 준비 전이거나 실패하면 null.
  SurfaceFeatures? estimate(CameraImage image, int rotationDegrees) {
    final session = _session;
    if (session == null) return null;

    final input =
        AngleEstimator.preprocessFrame(image, rotationDegrees, cropRatio: 1.0);
    if (input == null) return null;

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
    if (outputs.isEmpty) return null;
    final out = outputs.first as OrtValueTensor;
    final value = out.value as List;
    out.release();
    if (value.isEmpty) return null;
    return SurfaceFeatures.fromLogits(value.first as List);
  }

  void dispose() {
    _session?.release();
    _session = null;
  }
}
