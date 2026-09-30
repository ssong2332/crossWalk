import 'direction_resolver.dart';

/// T103(2026-09-27, 사용자 확정): **"횡단 중" 유지.**
///
/// X형(대각선) 교차 횡단보도는 가운데에 줄무늬가 없는 구간이 있다. 그 구간에서
/// 분류기는 none(줄무늬 없음)이나 approach(멀리 줄무늬)를 내는데, 사용자는
/// 아직 건너는 중이다. 그래서 횡단보도 위에서 줄무늬가 사라지면 곧바로 상태를
/// 바꾸지 않고 "횡단 중"([holdLabel])으로 붙잡아 둔다.
///
/// 다 건넘은 6-class의 `crossed`가 따로 알려 주므로(위 -> crossed = "건넜습니다"),
/// crossed가 나오기 전의 none/approach는 건넌 것이 아니라고 본다.
///
/// 판정표(사용자 확정):
///   | 직전 상태           | 이번 판정       | 유지 경과 | 결과                        |
///   | 위(front/left/right) | none / approach | —         | hold 시작                   |
///   | hold                | none / approach | < 10초    | hold 유지                   |
///   | hold                | none / approach | >= 10초   | 해제, 이번 판정 그대로       |
///   | hold                | 위 / crossed    | —         | 해제, 이번 판정 그대로       |
///   | 그 외               | 무엇이든        | —         | 이번 판정 그대로             |
///
/// hold 동안에는 **방향 안내를 멈춘다**(사용자 확정) — 줄무늬가 없으면 각도·
/// 위치 모델 값이 의미가 없다. 호출부(`CameraScreen`)는 hold일 때 음성·진동
/// 안내(`FeedbackService.alert`)를 부르지 않는다. 그래서 FeedbackService가 기억하는
/// 직전 상태는 마지막 "위" 상태로 남고, 이어서 crossed가 오면 "건넜습니다"가,
/// 위가 다시 오면 아무 안내 없이(진입 안내는 approach -> 위에서만) 이어진다.
/// 10초가 지나 해제되면 위 -> none/approach가 되는데, 둘 다 침묵이다(T103·T93 표).
///
/// 10초: 보행 약 1m/s에서 줄무늬 없는 구간 약 10m. 추정값이라 실기기 뒤 조정.
class CrossingHold {
  static const Duration holdDuration = Duration(seconds: 10);

  /// hold 상태를 나타내는 라벨. 분류기 라벨과 겹치지 않는다.
  static const String holdLabel = 'hold';

  DateTime? _since;

  bool get isHolding => _since != null;

  /// 직전 최종 상태 [current]와 이번 판정 [detected]로 실제로 쓸 상태를 낸다.
  String apply(String current, String detected, DateTime now) {
    final gap = detected == 'none' || detected == 'approach';
    final wasOn = DirectionResolver.isOnCrosswalk(current) ||
        (current == holdLabel && _since != null);
    if (gap && wasOn) {
      _since ??= now;
      if (now.difference(_since!) < holdDuration) return holdLabel;
    }
    _since = null;
    return detected;
  }
}
