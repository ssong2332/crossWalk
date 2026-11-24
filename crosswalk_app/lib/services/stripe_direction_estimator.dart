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

/// T67: 프레임별 각도 추정치를 화살표 회전에 쓸 수 있게 다듬는 순수 상태 기계.
///
/// 왜 필요한가:
/// - **떨림 억제**: 프레임마다 나온 raw 각도를 그대로 쓰면 화살표가 덜덜
///   떨린다. 지수이동평균(EMA)으로 부드럽게 만든다.
/// - **무판정 히스테리시스**: 한 프레임 무판정이 났다고 즉시 화살표를
///   놓아버리면 깜빡인다. [missTolerance]번 연속 무판정이어야 놓는다.
/// - **정직성**: 신뢰도가 [minConfidence] 미만인 추정은 아예 받지 않는다.
///   확신 없는 각도로 화살표를 돌리면 틀린 방향을 자신 있게 가리키게 된다.
///
/// 플러그인·위젯 의존이 전혀 없어 단위 테스트가 가능하다
/// (`test/stripe_angle_smoother_test.dart`).
class StripeAngleSmoother {
  StripeAngleSmoother({
    this.smoothingFactor = 0.35,
    this.missTolerance = 3,
    this.minConfidence = 0.25,
  });

  /// EMA 계수 — 0에 가까울수록 느리고 안정적, 1에 가까울수록 즉각적이고 떨린다.
  ///
  /// T70-3(2026-08-30): 기본값은 0.35였으나 실기기에서 표시 각도가 원시값보다
  /// 크게 뒤처졌다(예: 표시 9도 / 원시 24도). 연사 프레임으로 프레임간 예측
  /// 변화량을 실측한 결과 평균 8.1도(중앙 7.0도)였고, 갱신 약 3Hz 기준으로
  /// 계수별 특성은 다음과 같다:
  ///   0.35 -> 응답 약 0.95초, 통과 떨림 약 3.7도
  ///   0.60 -> 응답 약 0.56초, 통과 떨림 약 5.3도
  /// 모델 자체 오차가 13도대이므로 떨림 5.3도는 그 안에 묻히고 지연만 절반
  /// 가까이 줄어든다. 호출부(CameraScreen)는 0.6을 넘겨 쓴다.
  final double smoothingFactor;

  /// 이만큼 연속으로 무판정이 나야 각도를 놓는다(화살표가 기본 모양으로 복귀).
  final int missTolerance;

  /// 이 신뢰도 미만의 추정은 무판정과 동일하게 취급한다.
  /// `StripeDirectionEstimator`의 자체 임계값(0.2)보다 **높게** 잡았다 —
  /// 화면에 숫자로 보여주는 것보다 화살표를 실제로 돌리는 쪽이 더 확신을
  /// 요구하기 때문이다(틀린 방향을 가리키면 잘못된 정보가 된다).
  final double minConfidence;

  double? _angle;
  int _missStreak = 0;

  /// 현재 화살표에 쓸 각도(도). null이면 각도를 모르므로 호출부는 기존
  /// 고정 화살표로 되돌아가야 한다.
  double? get angleDegrees => _angle;

  /// 한 프레임의 추정 결과를 반영하고, 갱신된 각도를 돌려준다.
  /// T146: [factor]를 주면 이번 프레임만 [smoothingFactor] 대신 쓴다(서 있을 때 더 느리게).
  double? add(StripeDirectionEstimate? estimate, {double? factor}) {
    if (estimate == null || estimate.confidence < minConfidence) {
      _missStreak++;
      if (_missStreak >= missTolerance) _angle = null;
      return _angle;
    }

    _missStreak = 0;
    final current = _angle;
    _angle = current == null
        ? estimate.angleDegrees
        : current +
            (estimate.angleDegrees - current) * (factor ?? smoothingFactor);
    return _angle;
  }

  /// 카메라 재시작 등으로 이전 프레임과의 연속성이 끊길 때 호출한다.
  void reset() {
    _angle = null;
    _missStreak = 0;
  }
}
