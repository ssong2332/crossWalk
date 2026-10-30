import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:meta/meta.dart';
import 'package:onnxruntime/onnxruntime.dart';

/// T70: 학습된 회귀 모델로 화살표가 가리킬 **보정 방향**을 추정한다.
///
/// **이 값은 순수한 기하 각도가 아니다 (T74에서 확인).**
///   사용자가 라벨링할 때 횡단보도 내 좌우 위치에 따라 위험 가중을 더했다 —
///   가장자리에서 바깥으로 향하는 경우 각도를 일부러 크게 줬다. 위치 라벨
///   602장으로 실측한 결과 **위치 한 단계당 평균 +7.3도**였고, 가장자리에서
///   중앙으로 돌아오는 "반대" 경우는 오히려 중앙보다 작았다(19.8 vs 24.0도).
///   즉 출력은 "어느 쪽으로"와 "얼마나 급히"를 함께 담은 **보정량**이다.
///   그래서 (1) 예측을 사진과 대조해 기하학적으로 검증할 수 없고,
///   (2) 화면 표시를 "각도"라 쓰면 사용자를 오도한다(T75에서 "보정"으로 변경).
///   위험 가중을 통계적으로 제거하려 했으나 실패했다 — 선형 모형의 설명력이
///   R^2 0.204, 잔차 12.5도로, 보정해도 집단 평균이 맞지 않았다.
///
/// 왜 이 모델인가 (T67-2에서 실측):
///   고전 CV(`StripeDirectionEstimator`)는 평균 오차 34.5도로, 학습 없는
///   "항상 0도"(32.4도)보다도 나빴다. 파라미터 문제가 아니라 원근 때문에
///   "하나의 대표 각도"가 애초에 정의되지 않는 문제였다.
///
/// 성능 (v2 라벨 604장, 누수 없는 5-fold 교차검증 — docs/Tasks.md T74):
///   전체       평균  7.5도 / 중앙 4.8도 (±10도내 75%, ±15도내 87%)
///   2_front    평균  2.4도 (±10도내 99%)   <- 가장 흔한 상태, 사실상 해결
///   1_approach 평균  6.9도
///   4_right    평균 10.5도
///   3_left     평균 11.7도
///   **v1(558 라벨)의 12.2도와 직접 비교하면 안 된다.** v2는 라벨 각도 자체가
///   작아져 기준선("항상 0도")도 31.2 -> 16.5도로 내려갔다. 기준선 대비
///   상대오차로 보면 v1 0.391 / v2 0.457이다.
///
/// 상태 판정에는 쓰지 않는다 (T74에서 실측 후 기각):
///   "각도가 ±T도 안이면 직진"이라는 규칙을 분류기와 비교했다. 정확도는
///   각도규칙이 앞섰지만(92.9% vs 88.2%), 같은 장소 2초 간격 157쌍의 판정
///   변동률이 21.0% -> 38.2%로 두 배 가까이 나빠졌다. 각도 자체가 프레임 간
///   평균 18.0도 흔들리는데 경계 폭이 그보다 좁기 때문이다. 사용자가 가장
///   먼저 보고한 문제가 흔들림이라 정확도 +4.7%p와 맞바꾸지 않았다.
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

  /// 학습 시야(중앙 크롭 비율). 이 비율이 어긋나면 화각이 달라져 물체 크기가
  /// 학습 때와 맞지 않는다.
  /// T160: T159 모델(`train/t159_train.py` OPT crop=1.0)은 **화면 전체**를
  /// 224로 BILINEAR 리사이즈해 학습했다(캐시 크기 = round(224 / crop) = 224,
  /// center_crop 224 = 자르지 않음). 위치 모델(T98)과 같은 1.0이다.
  /// 종전 T103 모델은 288 리사이즈 후 중앙 224(= 224/288)였다.
  @visibleForTesting
  static const cropRatio = 1.0;

  /// T160: 앱에서 원본 + 좌우반전 2회 추론 후 평균할지. **꺼 둔다(false).**
  /// T159 검증 방식은 sign(평균 회귀) × 평균 순서형|각|이라, 출력 둘을 평균하면
  /// 부호가 엇갈릴 때 결과가 다르다. 그래서 반전 TTA를 그래프 안에 넣은 ONNX
  /// (`fullbw224_ord_reg_tta.onnx`)를 1회 호출한다(모델 안에서 2배 연산).
  /// true면 앱에서 2회 추론해 부호를 되돌려 평균한다(`t159_train.py` predict: s = -1 if flip).
  static const flipAverage = false;

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

  /// T160: 직전 [estimate]의 모델 추론 시간(ms, 1회 호출 — TTA 모델은 안에서 2배 연산.
  /// [flipAverage]를 켜면 2회 합).
  /// 전처리는 빼고 `session.run`만 잰다(폰 실측용, `angle` 기록 `inf`).
  int? lastInferenceMs;

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
  ///
  /// T98: `PositionEstimator`도 같은 전처리를 쓴다 — 다만 그 모델은 학습에서
  /// 중앙 크롭 없이 **화면 전체**를 224로 줄였으므로(`train_position.py`,
  /// 가장자리 단서를 살리기 위해) [cropRatio]를 1.0으로 넘긴다.
  static Float32List? preprocessFrame(CameraImage image, int rotationDegrees,
      {double cropRatio = AngleEstimator.cropRatio}) {
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

    // 학습 시야 [cropRatio]만큼 중앙을 잘라 224로 줄인다(1.0이면 화면 전체).
    // 이걸 어긋나게 하면 화각이 달라져 물체가 학습 때와 다른 크기로 보인다.
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
  /// T160: [flipAverage]면 좌우반전 입력도 돌려 (원본 − 반전) / 2로 평균한다.
  double? estimate(CameraImage image, int rotationDegrees) {
    lastInferenceMs = null;
    final session = _session;
    if (session == null) return null;

    final input = preprocessFrame(image, rotationDegrees);
    if (input == null) return null;

    final clock = Stopwatch()..start();
    final v = _run(session, input);
    if (v == null) return null;
    if (!flipAverage) {
      lastInferenceMs = clock.elapsedMilliseconds;
      return v * angleScale;
    }
    final f = _run(session, flipHorizontal(input));
    lastInferenceMs = clock.elapsedMilliseconds;
    if (f == null) return null;
    return flipAveraged(v, f) * angleScale;
  }

  /// T160: 원본 출력 [plain]과 좌우반전 입력의 출력 [flipped]를 평균한다.
  /// 반전하면 가야 할 방향이 거울상이라 부호를 되돌린다(`t159_train.py` predict).
  @visibleForTesting
  static double flipAveraged(double plain, double flipped) =>
      (plain - flipped) / 2.0;

  /// T160: NCHW(1x3x224x224) 텐서를 가로(W)로 뒤집는다 — `torch.flip(x, dims=[3])`과
  /// 같다(`t159_train.py` predict). 정규화 뒤 뒤집어도 픽셀마다 같은 변환이라 결과가 같다.
  @visibleForTesting
  static Float32List flipHorizontal(Float32List input) {
    final out = Float32List(input.length);
    const n = _inputSize;
    for (int row = 0; row < input.length ~/ n; row++) {
      final base = row * n;
      for (int x = 0; x < n; x++) {
        out[base + x] = input[base + n - 1 - x];
      }
    }
    return out;
  }

  double? _run(OrtSession session, Float32List input) {
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
    return v.toDouble();
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
