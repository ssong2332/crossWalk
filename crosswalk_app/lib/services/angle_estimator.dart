import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:meta/meta.dart';
import 'package:onnxruntime/onnxruntime.dart';

/// T70: 학습된 각도 회귀 모델로 **횡단보도 진행 방향**을 추정한다.
///
/// 왜 이 모델인가 (T67-2 / T69에서 실측):
///   고전 CV(`StripeDirectionEstimator`)는 사람 라벨 405장 기준 평균 오차
///   34.5도로, 학습 없는 "항상 0도"(32.4도)보다도 나빴다. 이 모델은 누수 없는
///   5-fold 교차검증에서 **평균 13.4도 / 중앙 7.5도**로 오차를 61% 줄였다.
///
/// 성능과 한계 (정직하게 병기 — docs/Tasks.md T69):
///   2_front    평균  4.1도 (±10도내 95%)   <- 가장 흔한 상태, 사실상 해결
///   1_approach 평균 10.5도
///   4_right    평균 17.4도
///   3_left     평균 24.5도
///   **큰 각도를 과소평가한다** — 회귀직선 기울기 0.709. ±60도를 넘는 정답에서
///   축소율 0.57~0.66. 선형 역보정을 실측했으나 오히려 악화되어(13.4->15.8)
///   기각했다. 확신이 없을 때 중앙으로 예측하는 것이 오차 최소화의 최적
///   반응이기 때문이며, 근본 해결은 큰 각도 라벨 보강이다.
///   **실패 양상은 안전한 쪽**: 방향(부호) 정확도 left 98% / right 98% —
///   반대 방향을 가리키는 일은 거의 없고 크기만 보수적으로 나온다.
///
/// 입력 방향 (가장 틀리기 쉬운 부분):
///   학습 라벨은 EXIF 보정된 **화면(세로) 방향** 기준이라, 센서 버퍼를 그대로
///   넣으면 약 90도 계통 오차가 난다. 그래서 전처리에서 `sensorOrientation`
///   만큼 시계방향 회전을 적용한다. 회전은 별도 디코딩 없이 **인덱스 매핑**으로
///   처리한다 — 전체 프레임을 RGB로 디코딩하면 92만 픽셀 루프가 한 번 더
///   돌지만, 어차피 224x224만 필요하므로 그 격자만 직접 샘플링하면 약 5만
///   회로 끝난다(분류기의 전체 디코딩보다도 싸다).
class AngleEstimator {
  static const _inputSize = 224;

  /// 학습은 288로 리사이즈한 뒤 중앙 224를 잘라낸다(`train_angle.py`의
  /// CACHE_SIZE=288, IMG_SIZE=224). 즉 모델이 실제로 보는 것은 화면
  /// 이미지의 중앙 224/288 영역이다. 이 비율이 어긋나면 화각이 달라져
  /// 물체 크기가 학습 때와 맞지 않는다.
  @visibleForTesting
  static const cropRatio = 224.0 / 288.0;

  /// 출력 픽셀 하나당 평균낼 원본 격자 크기(kxk).
  /// 실측(전체 405장, 배포 ONNX): 1이면 16.0도, 2면 13.7도, 3이면 13.3도
  /// (학습 전처리 기준 12.3도). 3에서 이득이 거의 포화된다.
  static const _sampleGrid = 3;

  /// 학습 시 각도를 이 값으로 나눠 정규화했다(`train/train_angle.py`의
  /// `ANGLE_SCALE`). 모델 출력에 다시 곱해야 도(degree)가 된다.
  /// 두 값이 어긋나면 각도가 조용히 배율만큼 틀어진다.
  static const angleScale = 90.0;

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

    final raw = await rootBundle.load('assets/model/crosswalk_angle.onnx');
    final bytes = raw.buffer.asUint8List();
    await _verifyIntegrity(bytes);
    _session = OrtSession.fromBuffer(bytes, OrtSessionOptions());
  }

  Future<void> _verifyIntegrity(Uint8List modelBytes) async {
    try {
      final expected =
          (await rootBundle.loadString('assets/model/crosswalk_angle.onnx.sha256'))
              .trim();
      if (expected.length == 64 &&
          sha256.convert(modelBytes).toString() != expected) {
        throw StateError('각도 모델 파일이 손상되었거나 변조되었습니다.');
      }
    } on StateError {
      rethrow;
    } catch (_) {
      // 해시 파일 없음 → 개발 환경, 건너뜀 (Classifier와 같은 정책)
    }
  }

  /// 센서 버퍼를 [rotationDegrees]만큼 **시계방향**으로 돌렸을 때의 화면
  /// 좌표 [dx],[dy]에 대응하는 **센서 좌표**를 돌려준다.
  ///
  /// `image` 패키지 `copyRotate`의 실제 구현(image 4.8.0
  /// lib/src/transform/copy_rotate.dart `_rotate90`: `dst(x,y) =
  /// src(y, H-1-x)`)과 동일한 관례를 따른다 — 즉 시계방향이다.
  /// 회전 방향이 틀리면 각도가 90/180도 어긋나므로 순수 함수로 분리해
  /// 단위 테스트로 고정한다.
  @visibleForTesting
  static List<int> sensorCoord(
    int dx,
    int dy,
    int rotationDegrees,
    int sensorWidth,
    int sensorHeight,
  ) {
    switch (rotationDegrees % 360) {
      case 90:
        return [dy, sensorHeight - 1 - dx];
      case 180:
        return [sensorWidth - 1 - dx, sensorHeight - 1 - dy];
      case 270:
        return [sensorWidth - 1 - dy, dx];
      default:
        return [dx, dy];
    }
  }

  /// 회전 후(=화면) 이미지의 크기. 90/270도에서는 가로세로가 바뀐다.
  @visibleForTesting
  static List<int> displaySize(int rotationDegrees, int w, int h) {
    final r = rotationDegrees % 360;
    return (r == 90 || r == 270) ? [h, w] : [w, h];
  }

  /// YUV420 프레임을 회전·축소·정규화해 모델 입력 텐서(NCHW)로 만든다.
  ///
  /// 전체 프레임을 RGB로 디코딩하지 않고 224x224 격자만 직접 샘플링한다.
  Float32List? _preprocess(CameraImage image, int rotationDegrees) {
    if (image.format.group != ImageFormatGroup.yuv420) return null;
    if (image.planes.length < 3) return null;

    final w = image.width;
    final h = image.height;
    final ds = displaySize(rotationDegrees, w, h);
    final dW = ds[0], dH = ds[1];

    final yPlane = image.planes[0].bytes;
    final uPlane = image.planes[1].bytes;
    final vPlane = image.planes[2].bytes;
    final yStride = image.planes[0].bytesPerRow;
    final uvStride = image.planes[1].bytesPerRow;
    final uvPixel = image.planes[1].bytesPerPixel ?? 1;

    // 학습(`train_angle.py`)은 288 정사각 리사이즈 후 **중앙 224 크롭**을 한다.
    // 즉 최종 입력은 화면 이미지의 중앙 224/288 = 77.8% 영역만 담는다.
    // 이걸 빠뜨리면 화각이 넓어져 물체가 학습 때보다 작게 보인다.
    final cw = (dW * cropRatio).toInt();
    final ch = (dH * cropRatio).toInt();
    final ox = (dW - cw) ~/ 2;
    final oy = (dH - ch) ~/ 2;

    // 학습(`train_angle.py`)과 동일한 ImageNet 정규화.
    const mean = [0.485, 0.456, 0.406];
    const std = [0.229, 0.224, 0.225];
    const plane = _inputSize * _inputSize;
    final buf = Float32List(3 * plane);

    for (int dy = 0; dy < _inputSize; dy++) {
      for (int dx = 0; dx < _inputSize; dx++) {
        // kxk 격자를 평균낸다 — 점 하나만 찍어 읽으면(최근접) 1280폭을
        // 224로 줄일 때 줄무늬 텍스처가 앨리어싱으로 뭉개진다. 학습은
        // 평균을 내는 BILINEAR 리사이즈를 썼으므로 여기서도 평균을 내야
        // 입력 분포가 맞는다. 실측(전체 405장): 평균 없이는 16.0도,
        // 3x3 평균이면 13.3도로 학습 전처리 기준(12.3도)에 근접한다.
        double rs = 0, gs = 0, bs = 0;
        int n = 0;
        for (int j = 0; j < _sampleGrid; j++) {
          final py = oy + ((dy * _sampleGrid + j) * ch) ~/ (_inputSize * _sampleGrid);
          for (int i = 0; i < _sampleGrid; i++) {
            final px =
                ox + ((dx * _sampleGrid + i) * cw) ~/ (_inputSize * _sampleGrid);
            final s = sensorCoord(px, py, rotationDegrees, w, h);
            final sx = s[0], sy = s[1];
            if (sx < 0 || sy < 0 || sx >= w || sy >= h) continue;

            final yIdx = sy * yStride + sx;
            if (yIdx >= yPlane.length) continue;
            final yVal = yPlane[yIdx];
            final uvIdx = (sy ~/ 2) * uvStride + (sx ~/ 2) * uvPixel;
            if (uvIdx >= uPlane.length || uvIdx >= vPlane.length) continue;
            final uVal = uPlane[uvIdx];
            final vVal = vPlane[uvIdx];

            rs += (yVal + 1.402 * (vVal - 128)).clamp(0, 255);
            gs += (yVal - 0.344136 * (uVal - 128) - 0.714136 * (vVal - 128))
                .clamp(0, 255);
            bs += (yVal + 1.772 * (uVal - 128)).clamp(0, 255);
            n++;
          }
        }
        if (n == 0) continue;

        final idx = dy * _inputSize + dx;
        buf[idx] = (rs / n / 255.0 - mean[0]) / std[0];
        buf[plane + idx] = (gs / n / 255.0 - mean[1]) / std[1];
        buf[2 * plane + idx] = (bs / n / 255.0 - mean[2]) / std[2];
      }
    }
    return buf;
  }

  /// 한 프레임의 진행 방향 각도(도)를 추정한다.
  /// 화면 위쪽이 0도, 시계방향이 +. 준비되지 않았거나 포맷이 다르면 null.
  ///
  /// [rotationDegrees]는 보통 `controller.description.sensorOrientation`.
  double? estimate(CameraImage image, int rotationDegrees) {
    final session = _session;
    if (session == null) return null;

    final input = _preprocess(image, rotationDegrees);
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
      // 예외가 나도 네이티브 자원은 반드시 해제한다(누수 방지).
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
    return v.toDouble() * angleScale;
  }

  void dispose() {
    _session?.release();
    _session = null;
    if (_envInitialized) {
      // OrtEnv는 Classifier와 공유되므로 여기서 release하지 않는다 —
      // 먼저 dispose되는 쪽이 해제하면 다른 쪽 세션이 죽는다.
      _envInitialized = false;
    }
  }
}
