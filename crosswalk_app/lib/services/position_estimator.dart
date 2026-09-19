import 'package:camera/camera.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';

import 'angle_estimator.dart';

/// T98: 횡단보도 **폭 안에서의 좌우 위치**를 추정하는 회귀 모델.
///
/// 출력 단위는 위치 라벨(`train/label_position.py`)과 같다:
///   -2 왼쪽 끝, -1 왼쪽 치우침, 0 중앙, +1 오른쪽 치우침, +2 오른쪽 끝.
/// 학습은 이 값을 [positionScale]로 나눠 -1~+1로 정규화했으므로 출력에
/// 다시 곱한다(`train_position.py`의 POS_SCALE). 두 값이 어긋나면 끝 판정
/// 임계(`DirectionResolver.edgePosition`)가 조용히 배율만큼 틀어진다.
///
/// 왜 별도 모델인가: 각도 모델에 위치를 라벨 가중으로 섞어 넣는 시도(T95)는
/// 학습되지 않았다(직진&끝 21장 중 0장). 위치를 **독립 출력**으로 두고 앱이
/// 규칙(`DirectionResolver` T98 표)으로 적용한다.
///
/// 입력 방향: 각도 모델과 같이 EXIF 보정된 **화면(세로) 방향**이다. 다만
/// 중앙 크롭 없이 화면 전체를 224로 줄인다 — 끝 판정은 화면 가장자리의
/// 연석·줄무늬 끝단 단서에 기대므로 크롭하면 그 단서가 잘린다.
/// 전처리는 `AngleEstimator.preprocessFrame(cropRatio: 1.0)`을 공유한다.
///
/// 성능(누수 없는 5-fold CV, 횡단보도 위 사진만): `train/position_cv_t98b.log`.
class PositionEstimator {
  static const _inputSize = 224;

  /// `train_position.py`의 POS_SCALE.
  static const positionScale = 2.0;

  OrtSession? _session;
  bool _envInitialized = false;

  bool get isReady => _session != null;

  Future<void> init() async {
    _session?.release();
    _session = null;

    if (!_envInitialized) {
      OrtEnv.instance.init();
      _envInitialized = true;
    }

    final raw = await rootBundle.load('assets/model/crosswalk_position.onnx');
    final bytes = raw.buffer.asUint8List();
    await _verifyIntegrity(bytes);
    _session = OrtSession.fromBuffer(bytes, OrtSessionOptions());
  }

  Future<void> _verifyIntegrity(Uint8List modelBytes) async {
    try {
      final expected = (await rootBundle
              .loadString('assets/model/crosswalk_position.onnx.sha256'))
          .trim();
      if (expected.length == 64 &&
          sha256.convert(modelBytes).toString() != expected) {
        throw StateError('위치 모델 파일이 손상되었거나 변조되었습니다.');
      }
    } on StateError {
      rethrow;
    } catch (_) {
      // 해시 파일 없음 → 개발 환경, 건너뜀 (AngleEstimator와 같은 정책)
    }
  }

  /// 한 프레임의 좌우 위치(-2~+2 단위, 연속값)를 추정한다.
  /// 준비되지 않았거나 포맷이 다르면 null.
  ///
  /// [rotationDegrees]는 보통 `controller.description.sensorOrientation`.
  double? estimate(CameraImage image, int rotationDegrees) {
    final session = _session;
    if (session == null) return null;

    final input =
        AngleEstimator.preprocessFrame(image, rotationDegrees, cropRatio: 1.0);
    if (input == null) return null;

    final tensor = OrtValueTensor.createTensorWithDataList(
      input,
      [1, 3, _inputSize, _inputSize],
    );
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
    final raw = out.value as List;
    out.release();
    if (raw.isEmpty) return null;

    final first = raw.first;
    final v = first is List ? (first.isEmpty ? null : first.first) : first;
    if (v is! num) return null;
    return v.toDouble() * positionScale;
  }

  void dispose() {
    _session?.release();
    _session = null;
    if (_envInitialized) {
      // OrtEnv는 Classifier/AngleEstimator와 공유되므로 release하지 않는다.
      _envInitialized = false;
    }
  }
}
