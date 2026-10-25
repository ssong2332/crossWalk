import 'dart:math' as math;

/// T133(사용자 승인 안 A, 2026-10-25): 가속도로 사용자가 서 있는지 판단한다.
///
/// 10/25 저녁 실기기(`train/field_1025b/report.md` '정지·대기 중 경고 되풀이'):
/// 줄무늬 앞에서 신호를 기다리는 대기 구간 8개 중 5개에서 음성 점유율이 50%를
/// 넘었다(54~69%). 서 있을 때는 같은 방향 음성 반복을 멈추고 진동만 낸다
/// (`FeedbackService.decideMessage`). 카메라 화면 변화 대신 가속도를 쓰는 것은
/// 화면 방식이 몸 흔들림에 약해서다(사용자 결정).
///
/// 움직임 크기 = 최근 [window] 동안 가속도 크기 |a|(중력 포함, m/s²)의 표준편차.
/// 중력 방향(폰 기울기)과 무관하고, 걸을 때의 발걸음 충격(상하 흔들림)을 잡는다.
///
/// 판정표 (시간은 인자로 주입):
///   | # | 조건                                                    | 결과                 |
///   | 1 | 표본이 [minSamples]개 미만(창이 덜 참)                    | 바꾸지 않음          |
///   | 2 | 움직임 >= [moveThreshold]                               | **바로** 서 있음 아님 |
///   | 3 | 움직임 < [stillThreshold]가 [holdOn] 이상 이어짐          | 서 있음              |
///   | 4 | 그 사이 값(둘 사이)                                      | 지금 상태 유지. 서 있음 아님이면 3의 시계를 처음부터 |
///   | 5 | 마지막 표본이 [staleAfter]보다 오래됨(센서 멈춤)            | [isStillAt]이 false  |
///
/// 기준값은 **추정값**이다(실측 전). 근거: 가슴 거치(목걸이형) 폰은 걸을 때 발걸음마다
/// 상하 가속이 크게 흔들려 |a|의 표준편차가 대략 1 m/s² 이상, 서서 숨쉬기·몸 흔들림은
/// 대략 0.2 m/s² 이하로 본다(일반적인 보행 가속도 범위 — 이 앱 기록으로 잰 값 아님).
/// 그 사이에 두 값을 두고 오르내림 간격(이력)을 줬다. 2초 유지는 걸음 사이 잠깐 멈칫한
/// 것을 서 있음으로 보지 않게 하려는 것이다. 걸음을 떼면 2번 규칙으로 바로 풀려 음성
/// 반복이 돌아온다(안전 쪽). 실기기 `still` 기록의 `mot`으로 조정한다.
class StillnessDetector {
  static const window = Duration(seconds: 1);
  static const stillThreshold = 0.35;
  static const moveThreshold = 0.6;
  static const holdOn = Duration(seconds: 2);
  static const staleAfter = Duration(seconds: 1);
  static const minSamples = 5;

  final List<(DateTime, double)> _samples = [];
  bool _still = false;
  DateTime? _quietSince;
  DateTime? _lastSampleAt;
  double? _motion;

  /// 마지막 판정 상태(센서가 멈췄는지는 보지 않음 — [isStillAt]을 쓴다).
  bool get isStill => _still;

  /// 마지막으로 계산한 움직임 크기(m/s², 기록용). 창이 덜 찼으면 null.
  double? get motion => _motion;

  /// 지금 서 있다고 볼 것인가. 센서 표본이 [staleAfter]보다 오래되면 false.
  bool isStillAt(DateTime now) {
    final last = _lastSampleAt;
    return _still && last != null && now.difference(last) <= staleAfter;
  }

  /// 가속도 표본 하나(m/s², 중력 포함)를 넣는다. 서 있음 상태가 바뀌었으면 true.
  bool add(double x, double y, double z, DateTime now) {
    _lastSampleAt = now;
    _samples.add((now, math.sqrt(x * x + y * y + z * z)));
    final cutoff = now.subtract(window);
    _samples.removeWhere((s) => s.$1.isBefore(cutoff));
    if (_samples.length < minSamples) return false;
    final n = _samples.length;
    final mean = _samples.fold<double>(0, (a, s) => a + s.$2) / n;
    final variance =
        _samples.fold<double>(0, (a, s) => a + (s.$2 - mean) * (s.$2 - mean)) / n;
    final motion = math.sqrt(variance);
    _motion = motion;
    final was = _still;
    if (motion >= moveThreshold) {
      _still = false;
      _quietSince = null;
    } else if (motion < stillThreshold) {
      _quietSince ??= now;
      if (!_still && now.difference(_quietSince!) >= holdOn) _still = true;
    } else if (!_still) {
      _quietSince = null;
    }
    return _still != was;
  }

  void reset() {
    _samples.clear();
    _still = false;
    _quietSince = null;
    _lastSampleAt = null;
    _motion = null;
  }
}
