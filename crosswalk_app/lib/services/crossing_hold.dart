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
///
/// T118(2026-10-17, 사용자 선택 A2): **발밑이 인도면 일찍 해제.** 10/16 기록
/// (183810)에서 횡단보도 끝에 섰다가 인도로 돌아섰는데 10초 동안 "횡단 중"이
/// 이어졌다(L1370~L1428, 8.5초부터 노면 앞 구역 인도+점자블록 0.96~1.0).
///   | hold 중 노면 앞 구역(인도+선형+점형)  | 결과                              |
///   | >= [groundReleaseRatio], [groundReleaseFrames]회 연속 | 다음 판정에서 해제, 이번 판정 그대로 |
///   | 그 밖                                  | 위 표대로(10초)                    |
/// X형 가운데 빈 구간은 아스팔트(차도)라 이 조건에 걸리지 않는다(추정).
/// 노면 판정은 노면·주의 구역 스위치 중 하나가 켜져 있어야 돈다 — 꺼져 있으면
/// 이 규칙도 쉬고 10초 규칙만 남는다. 이렇게 풀린 직후의 crossed는
/// `FeedbackService.noteHoldReleasedByGround`가 "건넜습니다"를 지킨다.
///
/// T140(2026-10-27, 사용자 승인 "전부 추천대로 진행하자"): **오래 건넌 뒤 발밑
/// 인도로 풀리면 "건넜습니다".** 10/27 낮 기록(121630)에서 분류기가 맞은편 끝에서
/// crossed를 거의 내지 않아(끝 10곳 crossed 평균 최대 0.01~0.53, 기준 0.55)
/// 실제 끝 10곳이 모두 hold → 발밑 인도 해제 → none으로 조용히 끝났다.
///   | 발밑 인도로 해제될 때 위 지속([releasedOnDuration]) | 결과                 |
///   | >= [groundReleaseCrossedMinOn]                       | "건넜습니다" 요청    |
///   | 그 밖(또는 모름)                                     | 지금처럼 침묵        |
/// 위 지속 = 최종 상태가 위가 아닌 곳(hold 제외)에서 위로 들어온 시각부터 해제
/// 시각까지. 그 사이 위 ↔ hold 오감은 이어진 것으로 본다. 10초 만료 해제는 바꾸지
/// 않는다. 6초는 추정값 — 기록 적용 결과는 `docs/Tasks.md` T140.
class CrossingHold {
  static const Duration holdDuration = Duration(seconds: 10);

  /// T118: 인도+점자블록 비율 기준(추정값, 실기기 뒤 조정).
  static const double groundReleaseRatio = 0.5;

  /// T118: 연속 횟수. 노면 판정은 약 0.5초마다 한 번이다(처리 프레임 10개 중 1개).
  static const int groundReleaseFrames = 2;

  /// T140: 발밑 인도 해제 때 "건넜습니다"를 낼 최소 위 지속(추정값).
  static const Duration groundReleaseCrossedMinOn = Duration(seconds: 6);

  /// hold 상태를 나타내는 라벨. 분류기 라벨과 겹치지 않는다.
  static const String holdLabel = 'hold';

  DateTime? _since;
  int _groundStreak = 0;
  bool _releasedByGround = false;

  bool get isHolding => _since != null;

  /// T118: 바로 직전 [apply]가 "발밑이 인도"라서 hold를 풀었는가.
  bool get releasedByGround => _releasedByGround;

  /// T118 보완: [releasedByGround]일 때 그 hold가 시작된 시각(그 밖에는 null).
  DateTime? get releasedHoldStartedAt => _releasedHoldStartedAt;
  DateTime? _releasedHoldStartedAt;

  /// T140: 최종 상태가 위로 들어온 시각(위 ↔ hold 동안 유지). 위·hold가 아니면 null.
  DateTime? _onSince;

  /// T140: [releasedByGround]일 때 위 지속(위로 들어온 뒤 해제까지). 그 밖에는 null.
  Duration? get releasedOnDuration => _releasedOnDuration;
  Duration? _releasedOnDuration;

  /// T140: [releasedByGround]이고 [releasedOnDuration] >= [groundReleaseCrossedMinOn].
  bool get releasedAfterLongCrossing =>
      _releasedOnDuration != null &&
      _releasedOnDuration! >= groundReleaseCrossedMinOn;

  /// T118: hold 중 노면 판정 한 번. [sidewalkAndBlocks]는 노면 앞 구역의
  /// 인도+선형+점형 비율. hold가 아니면 셈을 비운다.
  void noteGround(double sidewalkAndBlocks) {
    if (_since == null) {
      _groundStreak = 0;
      return;
    }
    _groundStreak =
        sidewalkAndBlocks >= groundReleaseRatio ? _groundStreak + 1 : 0;
  }

  /// 직전 최종 상태 [current]와 이번 판정 [detected]로 실제로 쓸 상태를 낸다.
  String apply(String current, String detected, DateTime now) {
    _releasedByGround = false;
    _releasedHoldStartedAt = null;
    _releasedOnDuration = null;
    final gap = detected == 'none' || detected == 'approach';
    final wasOn = DirectionResolver.isOnCrosswalk(current) ||
        (current == holdLabel && _since != null);
    if (gap && wasOn) {
      _since ??= now;
      if (_groundStreak >= groundReleaseFrames) {
        _releasedByGround = true;
        _releasedHoldStartedAt = _since;
        if (_onSince != null) _releasedOnDuration = now.difference(_onSince!);
      } else if (now.difference(_since!) < holdDuration) {
        return holdLabel;
      }
    }
    _since = null;
    _groundStreak = 0;
    _trackOn(current, detected, now);
    return detected;
  }

  /// T140: 이번 결과 [result]로 위 지속 시작 시각을 갱신한다(hold 반환 경로는 유지).
  void _trackOn(String current, String result, DateTime now) {
    if (!DirectionResolver.isOnCrosswalk(result)) {
      _onSince = null;
    } else if (!DirectionResolver.isOnCrosswalk(current) &&
        current != holdLabel) {
      _onSince = now;
    } else {
      _onSince ??= now;
    }
  }
}
