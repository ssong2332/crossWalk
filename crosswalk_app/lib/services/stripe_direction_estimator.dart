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
class StripeDirectionEstimate {
  /// 수평(0도) 기준 기울기, 도 단위, 범위 (-maxTiltDegrees, +maxTiltDegrees].
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

class StripeDirectionEstimator {
  StripeDirectionEstimator._();

  /// 그레이스케일 버퍼(예: YUV420 카메라 프레임의 Y 플레인, 별도 RGB 변환
  /// 없이 그대로 쓸 수 있다)에서 우세 에지 방향을 추정한다.
  ///
  /// [sampleStride]: 성능을 위한 다운샘플 간격(픽셀). 값이 클수록 빠르지만
  /// 성긴 격자로 계산해 정밀도가 떨어진다. 실기기 프레임레이트 측정 없이
  /// 고른 잠정값(4) — 실기기 프로파일링 후 조정 필요.
  /// [gradientThreshold]: 이 미만의 그라디언트 크기는 에지로 치지 않는다
  /// (평탄한 노면/하늘 등 노이즈 제외).
  /// [maxTiltDegrees]: 이 각도보다 수직에 가까운 에지(가로등·건물 모서리 등
  /// 도심 배경의 흔한 수직 구조물)는 횡단보도 줄무늬가 아니라고 보고 무시한다.
  /// [minConfidence]: 우세 각도 구간의 집중도가 이 미만이면(뚜렷한 우세
  /// 방향이 없으면) null을 반환한다 — 모르는 것을 아는 척하지 않는다
  /// (Classifier의 threshold-미달 시 null 반환과 동일한 원칙).
  static StripeDirectionEstimate? estimate({
    required Uint8List gray,
    required int width,
    required int height,
    required int rowStride,
    int sampleStride = 4,
    double gradientThreshold = 24.0,
    double maxTiltDegrees = 60.0,
    double minConfidence = 0.12,
  }) {
    // 1도 단위 히스토그램, 인덱스 0..180 은 -90..+90도에 대응.
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

        if (angleDeg.abs() > maxTiltDegrees) continue; // 수직에 가까운 배경 구조물 제외

        final bin = (angleDeg + 90).round().clamp(0, 180);
        histogram[bin] += mag;
        totalWeight += mag;
      }
    }

    if (totalWeight <= 0) return null;

    int peakBin = 0;
    for (int i = 1; i < histogram.length; i++) {
      if (histogram[i] > histogram[peakBin]) peakBin = i;
    }

    // 우세 각도 주변 ±3도 창 안의 가중 평균으로 각도를 정련하고,
    // 그 창에 몰린 비율을 신뢰도로 쓴다(단일 1도 bin만 보면 노이즈에 민감).
    const window = 3;
    double windowWeightedSum = 0.0;
    double windowWeight = 0.0;
    for (int i = math.max(0, peakBin - window);
        i <= math.min(180, peakBin + window);
        i++) {
      final w = histogram[i];
      windowWeightedSum += (i - 90) * w;
      windowWeight += w;
    }
    if (windowWeight <= 0) return null;

    final angle = windowWeightedSum / windowWeight;
    final confidence = windowWeight / totalWeight;
    if (confidence < minConfidence) return null;

    return StripeDirectionEstimate(angle, confidence);
  }
}
