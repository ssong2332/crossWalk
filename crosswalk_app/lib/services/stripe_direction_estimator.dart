import 'dart:math' as math;
import 'dart:typed_data';

/// T66 프로토타입: 횡단보도 줄무늬(스트라이프)의 실시간 기울기를 **학습 없이**
/// 고전적 영상처리(Sobel 에지 검출 + 방향 히스토그램)로 추정한다.
///
/// 배경 — `Classifier`가 왜 이걸 낼 수 없는지: 학습 데이터의 라벨은
/// `none/approach/front/left/right` 5개 클래스뿐이고 기울기(각도) 정답이
/// 없어서, 같은 데이터로 재학습해도 각도를 배울 수 없다(사용자 논의,
/// 2026-08-24). 이 클래스는 재학습이 아니라 **매 프레임 기하학적으로 계산**한다
/// — 사람이 사진을 보고 "몇 도 기울었다"고 판단하는 것과 같은 방식은 아니고,
/// 에지의 우세한 방향을 통계적으로 찾는 방식이다.
///
/// 정직성 제약: 이 추정치는 **합성(이상적인) 줄무늬 패턴**으로만 검증됐다
/// (`test/stripe_direction_estimator_test.dart`). 실제 카메라 프레임(원근
/// 왜곡, 그림자, 젖은 노면 반사, 차선 등 다른 흰 선, 저조도 노이즈)에서
/// 얼마나 정확한지는 **미검증**이다 — 이 환경에 카메라 기기가 없다.
///
/// T66-3(2026-08-24, 사용자 실기기 관찰): `Classifier`가 "오른쪽으로 과하게
/// 이탈"이라고 판정한 프레임에서도 이 추정치가 무판정으로 나오는 경우가
/// 보고됐다. 두 시스템은 서로 다른 근거로 판단한다 — `Classifier`는 학습된
/// 이미지 특징(좌표·각도 모름)으로 판정하고, 이 클래스는 실제 에지 기하로만
/// 판단한다. 왜 무판정인지(에지 자체가 없음 / 우세 방향이 근수직이라
/// 걸러짐 / 우세 방향이 흩어져 신뢰도 미달) 구분할 수 있도록
/// [StripeDirectionDiagnostic]을 추가했다.
enum StripeDirectionNullReason {
  /// 성공 — [StripeDirectionDiagnostic.estimate]가 null이 아니다.
  none,

  /// 그라디언트 크기가 임계값을 넘는 에지 자체가 거의 없다(흐림·저대비·저조도).
  noEdges,

  /// 우세한 에지 방향은 뚜렷한데, 그 방향이 [maxTiltDegrees]보다 수직에
  /// 가까워 배경 구조물(건물·가로등 등)로 보고 걸러냈다.
  /// [StripeDirectionDiagnostic.rejectedAngleDegrees]에 걸러진 각도가 담긴다.
  tooVertical,

  /// 에지는 있지만 방향이 여러 각도로 흩어져 있어 우세 방향이라 할 만한
  /// 것이 없다(신뢰도가 [minConfidence] 미만).
  lowConfidence,
}

class StripeDirectionEstimate {
  /// 수평(0도) 기준 기울기, 도 단위, 범위 (-90, 90].
  final double angleDegrees;

  /// 추정 신뢰도 — 우세 각도 구간에 몰린 에지 가중치 비율(0~1). 절대적인
  /// 확률이 아니라 "다른 각도 대비 얼마나 뚜렷하게 우세한가"의 근사치다.
  final double confidence;

  const StripeDirectionEstimate(this.angleDegrees, this.confidence);

  @override
  String toString() =>
      'StripeDirectionEstimate(${angleDegrees.toStringAsFixed(1)}°, '
      'conf=${confidence.toStringAsFixed(2)})';
}

/// [StripeDirectionEstimator.diagnose]의 결과 — 성공/실패와 **실패 이유**를
/// 함께 담는다. `estimate`가 null일 때 [reason]으로 어떤 종류의 무판정인지
/// 구분할 수 있다.
class StripeDirectionDiagnostic {
  final StripeDirectionEstimate? estimate;
  final StripeDirectionNullReason reason;

  /// [reason]이 [StripeDirectionNullReason.tooVertical]일 때만 값이 있다 —
  /// 필터링되기 전 실제 우세 각도(도 단위).
  final double? rejectedAngleDegrees;

  const StripeDirectionDiagnostic(
    this.estimate,
    this.reason, {
    this.rejectedAngleDegrees,
  });
}

class StripeDirectionEstimator {
  StripeDirectionEstimator._();

  /// 그레이스케일 버퍼(예: YUV420 카메라 프레임의 Y 플레인, 별도 RGB 변환
  /// 없이 그대로 쓸 수 있다)에서 우세 에지 방향을 추정한다.
  ///
  /// 기존 호출부 호환을 위해 남겨둔 얇은 래퍼 — 진단 정보가 필요하면
  /// [diagnose]를 쓴다.
  static StripeDirectionEstimate? estimate({
    required Uint8List gray,
    required int width,
    required int height,
    required int rowStride,
    int sampleStride = 4,
    double gradientThreshold = 24.0,
    double maxTiltDegrees = 60.0,
    double minConfidence = 0.2,
    int angleWindowDegrees = 10,
  }) {
    return diagnose(
      gray: gray,
      width: width,
      height: height,
      rowStride: rowStride,
      sampleStride: sampleStride,
      gradientThreshold: gradientThreshold,
      maxTiltDegrees: maxTiltDegrees,
      minConfidence: minConfidence,
      angleWindowDegrees: angleWindowDegrees,
    ).estimate;
  }

  /// [estimate]와 같은 계산을 하되, 무판정일 때 **왜** 무판정인지
  /// ([StripeDirectionNullReason])까지 함께 반환한다.
  ///
  /// [sampleStride]: 성능을 위한 다운샘플 간격(픽셀). 값이 클수록 빠르지만
  /// 성긴 격자로 계산해 정밀도가 떨어진다. 실기기 프레임레이트 측정 없이
  /// 고른 잠정값(4) — 실기기 프로파일링 후 조정 필요.
  /// [gradientThreshold]: 이 미만의 그라디언트 크기는 에지로 치지 않는다
  /// (평탄한 노면/하늘 등 노이즈 제외).
  /// [maxTiltDegrees]: 이 각도보다 수직에 가까운 우세 에지(가로등·건물
  /// 모서리 등 도심 배경의 흔한 수직 구조물)는 횡단보도 줄무늬가 아니라고
  /// 보고 무시한다.
  /// [minConfidence]: 우세 각도 구간의 집중도가 이 미만이면(뚜렷한 우세
  /// 방향이 없으면) 무판정 처리한다 — 모르는 것을 아는 척하지 않는다
  /// (Classifier의 threshold-미달 시 null 반환과 동일한 원칙).
  /// [angleWindowDegrees]: 우세 각도 주변 몇 도까지를 "같은 방향"으로 묶어
  /// 신뢰도를 계산할지. **T66-4에서 3 → 10으로 올렸다.** 실제 횡단보도는
  /// (1) 원근 때문에 화면 위/아래에서 줄무늬 각도가 다르고 (2) 페인트가
  /// 갈라져 에지 방향이 넓게 퍼진다 — ±3도로는 그 퍼짐을 담지 못해
  /// 신뢰도가 임계값 밑으로 떨어져 계속 `lowConfidence` 무판정이 났다
  /// (2026-08-24 사용자 실기기 사진 3장에서 재현).
  ///
  /// 값 선정 근거(파이썬으로 이 알고리즘을 그대로 재현해 실측):
  /// 원근+균열 조건에서 ±3도는 신뢰도 0.12~0.17로 무판정, ±10도는
  /// 0.25~0.62로 통과. ±12도 이상으로 더 넓히면 **무작위 노이즈까지
  /// 0.21로 통과해 오탐**이 생기므로 10이 상한이다(노이즈 4개 시드에서
  /// ±10도는 0.172~0.182로 전부 거부됨).
  static StripeDirectionDiagnostic diagnose({
    required Uint8List gray,
    required int width,
    required int height,
    required int rowStride,
    int sampleStride = 4,
    double gradientThreshold = 24.0,
    double maxTiltDegrees = 60.0,
    double minConfidence = 0.2,
    int angleWindowDegrees = 10,
  }) {
    // 1도 단위 히스토그램, 인덱스 0..180 은 -90..+90도에 대응.
    // T66-3: 각도 필터링 전에 **모든** 방향의 에지를 히스토그램에 담는다
    // (이전엔 필터링된 방향은 아예 집계에서 빠져, "근수직이라 걸러짐"과
    // "애초에 에지가 없음"을 구분할 수 없었다).
    final histogram = List<double>.filled(181, 0.0);
    double totalWeight = 0.0;

    for (int y = sampleStride; y < height - sampleStride; y += sampleStride) {
      final rowAbove = (y - 1) * rowStride;
      final row = y * rowStride;
      final rowBelow = (y + 1) * rowStride;
      for (int x = sampleStride; x < width - sampleStride; x += sampleStride) {
        // Sobel 3x3.
        final tl = gray[rowAbove + x - 1], tc = gray[rowAbove + x], tr = gray[rowAbove + x + 1];
        final ml = gray[row + x - 1], mr = gray[row + x + 1];
        final bl = gray[rowBelow + x - 1], bc = gray[rowBelow + x], br = gray[rowBelow + x + 1];

        final gx = (tr + 2 * mr + br) - (tl + 2 * ml + bl);
        final gy = (bl + 2 * bc + br) - (tl + 2 * tc + tr);
        final mag = math.sqrt((gx * gx + gy * gy).toDouble());
        if (mag < gradientThreshold) continue;

        // 에지(줄무늬 경계선) 방향 = 그라디언트를 90도 회전한 접선 방향.
        // (-90,90] 범위로 정규화 — 선의 각도는 180도 주기이므로.
        double angleDeg = math.atan2(gx.toDouble(), -gy.toDouble()) * 180 / math.pi;
        while (angleDeg <= -90) {
          angleDeg += 180;
        }
        while (angleDeg > 90) {
          angleDeg -= 180;
        }

        final bin = (angleDeg + 90).round().clamp(0, 180);
        histogram[bin] += mag;
        totalWeight += mag;
      }
    }

    if (totalWeight <= 0) {
      return const StripeDirectionDiagnostic(
        null,
        StripeDirectionNullReason.noEdges,
      );
    }

    // maxTiltDegrees 안쪽(수평에 가까운) bin 범위. 원래 구현(T66)은 이
    // 범위 밖의 에지를 아예 히스토그램에 넣지 않고 버렸다 — 그래서 "근수직이라
    // 걸러짐"과 "애초에 에지가 없음"을 구분할 수 없었다(T66-3 CAVEAT). 여기서는
    // 전부 담아두고, 판정 단계에서만 범위를 나눈다 — 판정 로직 자체는 원래와
    // 동일한 수치를 낸다(범위 안에서만 우세 bin을 찾고, 그 범위의 총가중치로
    // 신뢰도를 나눈다).
    final lowBin = (90 - maxTiltDegrees).clamp(0, 180).round();
    final highBin = (90 + maxTiltDegrees).clamp(0, 180).round();

    double totalInRangeWeight = 0.0;
    for (int i = lowBin; i <= highBin; i++) {
      totalInRangeWeight += histogram[i];
    }

    if (totalInRangeWeight <= 0) {
      // 범위 안에는 에지가 전혀 없다 — 전체 중 우세 방향(반드시 범위 밖)을
      // 찾아 진단용으로 알려준다.
      int globalPeakBin = 0;
      for (int i = 1; i < histogram.length; i++) {
        if (histogram[i] > histogram[globalPeakBin]) globalPeakBin = i;
      }
      return StripeDirectionDiagnostic(
        null,
        StripeDirectionNullReason.tooVertical,
        rejectedAngleDegrees: (globalPeakBin - 90).toDouble(),
      );
    }

    int peakBin = lowBin;
    for (int i = lowBin + 1; i <= highBin; i++) {
      if (histogram[i] > histogram[peakBin]) peakBin = i;
    }

    // 우세 각도 주변 창 안의 가중 평균으로 각도를 정련하고, 그 창에 몰린
    // 비율을 신뢰도로 쓴다(단일 1도 bin만 보면 노이즈에 민감).
    final window = angleWindowDegrees;
    double windowWeightedSum = 0.0;
    double windowWeight = 0.0;
    for (int i = math.max(0, peakBin - window);
        i <= math.min(180, peakBin + window);
        i++) {
      final w = histogram[i];
      windowWeightedSum += (i - 90) * w;
      windowWeight += w;
    }
    if (windowWeight <= 0) {
      return const StripeDirectionDiagnostic(
        null,
        StripeDirectionNullReason.noEdges,
      );
    }

    final angle = windowWeightedSum / windowWeight;
    final confidence = windowWeight / totalInRangeWeight;

    if (confidence < minConfidence) {
      return const StripeDirectionDiagnostic(
        null,
        StripeDirectionNullReason.lowConfidence,
      );
    }

    return StripeDirectionDiagnostic(
      StripeDirectionEstimate(angle, confidence),
      StripeDirectionNullReason.none,
    );
  }
}
