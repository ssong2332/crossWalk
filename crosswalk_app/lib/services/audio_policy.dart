import 'package:meta/meta.dart';

/// 오디오 우선순위 정책 — `docs/AudioPolicy.md`의 판정표를 그대로 옮긴 순수 로직.
///
/// 플러그인(TTS/진동)에 의존하지 않으므로 단위 테스트로 전수 검증할 수 있다.
/// `FeedbackService`는 이 클래스에 "지금 말해도 되는가"를 물어보기만 한다.
///
/// 왜 분리했나: `feedback_service.dart`는 경쟁 상태를 6라운드 리뷰로 굳혀 놓은
/// 안전 코드다. 정책 판단을 그 안에 섞으면 그 보증이 흐려진다.
enum FeedbackPriority {
  /// 지금 위험. 늦으면 다친다. 무음 예산·최소 간격에서 **면제**된다.
  p0,

  /// 곧 행동해야 한다. (신호 변화, 경로 회전 지점 — 아직 사용처 없음)
  p1,

  /// 알면 좋다. (approach 방향 안내, 도착 — 아직 사용처 없음)
  p2,

  /// 앱 상태. (오류 안내, 온보딩 낭독)
  p3,
}

/// 정책이 내린 결정.
enum SpeechAction {
  /// 지금 발화한다. 재생 중인 것이 있으면 끊는다.
  speakNow,

  /// 재생 중인 P0가 끝날 때까지 대기 슬롯에 넣는다. (P1이 P0를 기다리는 한 칸뿐)
  queue,

  /// 버린다. 큐에 쌓지 않는다 — 늦게 도착한 안내는 정보가 아니라 오정보다.
  drop,
}

@immutable
class _Span {
  final DateTime start;
  final DateTime end;
  const _Span(this.start, this.end);
}

class AudioPolicy {
  // docs/AudioPolicy.md §4. **전부 추정값이며 실기기 보행 테스트로 조정해야 한다.**
  static const minGap = Duration(milliseconds: 1500);
  static const budgetWindow = Duration(seconds: 60);
  static const budgetLimit = Duration(seconds: 20);

  // docs/AudioPolicy.md §3.
  static const ttl = <FeedbackPriority, Duration>{
    FeedbackPriority.p0: Duration(seconds: 1),
    FeedbackPriority.p1: Duration(seconds: 3),
    FeedbackPriority.p2: Duration(seconds: 5),
    FeedbackPriority.p3: Duration.zero,
  };

  FeedbackPriority? _active;
  DateTime? _lastSpeechEnd;
  final List<_Span> _spans = <_Span>[];

  /// 대기 슬롯 — 최대 1개. 더 높은 등급이 오면 덮어쓴다.
  FeedbackPriority? pendingPriority;
  String? pendingMessage;
  DateTime? pendingAt;

  FeedbackPriority? get activePriority => _active;

  /// 60초 이동창 안에서 (P0을 제외하고) 이미 발화한 총 시간.
  ///
  /// P0을 누적하지 않는 이유: 안전 경고가 이후의 안전 경고를 막으면 안 된다.
  Duration spokenInWindow(DateTime now) {
    final cutoff = now.subtract(budgetWindow);
    var total = Duration.zero;
    for (final s in _spans) {
      if (s.end.isBefore(cutoff)) continue;
      final start = s.start.isBefore(cutoff) ? cutoff : s.start;
      total += s.end.difference(start);
    }
    return total;
  }

  /// docs/AudioPolicy.md §2 판정표. 부수효과가 없으므로 테스트에서 직접 호출해
  /// 전수 검증할 수 있고, `FeedbackService._speak`도 이것만 보고 집행한다.
  SpeechAction decide(FeedbackPriority incoming, DateTime now) {
    final active = _active;

    if (active != null) {
      // 더 높은 등급(index가 작음) 또는 같은 등급 -> 끊고 교체.
      if (incoming.index <= active.index) {
        // 유일한 예외: P0가 재생 중일 때 들어온 P1은 끊지 않고 기다린다.
        if (incoming == FeedbackPriority.p1 && active == FeedbackPriority.p0) {
          return SpeechAction.queue;
        }
        return SpeechAction.speakNow;
      }
      // P0 재생 중 + P1 요청 -> 대기 (위 조건에 걸리지 않으므로 여기서 처리)
      if (incoming == FeedbackPriority.p1 && active == FeedbackPriority.p0) {
        return SpeechAction.queue;
      }
      return SpeechAction.drop;
    }

    // 재생 중인 것이 없다. P0는 예산·간격을 무시하고 즉시 나간다.
    if (incoming == FeedbackPriority.p0) return SpeechAction.speakNow;

    final last = _lastSpeechEnd;
    if (last != null && now.difference(last) < minGap) return SpeechAction.drop;
    if (spokenInWindow(now) >= budgetLimit) return SpeechAction.drop;
    return SpeechAction.speakNow;
  }

  /// TTL이 지났는지. 대기 슬롯에서 꺼낼 때와 요청 시점 모두에서 쓴다.
  bool isExpired(FeedbackPriority priority, DateTime requestedAt, DateTime now) {
    final limit = ttl[priority] ?? Duration.zero;
    return now.difference(requestedAt) > limit;
  }

  void markStarted(FeedbackPriority priority) {
    _active = priority;
  }

  /// 발화가 끝났을 때 호출. P0는 예산에 누적하지 않는다(§4).
  void markFinished(FeedbackPriority priority, DateTime start, DateTime end) {
    if (_active == priority) _active = null;
    _lastSpeechEnd = end;
    if (priority != FeedbackPriority.p0) {
      _spans.add(_Span(start, end));
      final cutoff = end.subtract(budgetWindow);
      _spans.removeWhere((s) => s.end.isBefore(cutoff));
    }
  }

  void putPending(FeedbackPriority priority, String message, DateTime now) {
    // 더 높은 등급만 대기 슬롯을 덮어쓴다.
    final cur = pendingPriority;
    if (cur != null && priority.index > cur.index) return;
    pendingPriority = priority;
    pendingMessage = message;
    pendingAt = now;
  }

  void clearPending() {
    pendingPriority = null;
    pendingMessage = null;
    pendingAt = null;
  }

  @visibleForTesting
  void reset() {
    _active = null;
    _lastSpeechEnd = null;
    _spans.clear();
    clearPending();
  }
}

/// 진동 정책 — docs/AudioPolicy.md §5.
///
/// 좌/우가 같은 패턴이던 것을 분리한다. 도로 소음에 음성이 묻혀도 방향이 전달되도록,
/// 그리고 같은 방향이 지속될 때 음성 대신 진동만으로 알리기 위해서다.
class VibrationPolicy {
  /// 같은 방향이 계속될 때 방향 패턴을 다시 내는 간격.
  ///
  /// 3초는 `feedback_service.dart`의 `_cooldownSeconds`와 같은 값이다 —
  /// 음성 재발화와 같은 박자로 나가야 두 채널이 어긋나지 않는다.
  /// 초판의 간격 점증(1->2->4->8초)은 제거했다: 진동이 8초 간격이면
  /// 음성만 나가고 진동은 없는 구간이 생긴다.
  static const repeatInterval = Duration(seconds: 3);

  String? _lastClass;
  DateTime? _lastVibratedAt;

  String? get lastClass => _lastClass;

  /// `Vibration.vibrate(pattern:)`에 넣을 패턴을 돌려준다. null이면 진동하지 않는다.
  ///
  /// [longMs]는 사용자가 설정에서 조정하는 진동 길이다. 짧은 진동은 그 1/4이며
  /// 하한 80ms — 설정을 최소로 낮춰도 두 번의 진동이 한 번처럼 뭉치지 않게 한다.
  List<int>? decidePattern(String detectedClass, DateTime now, int longMs) {
    final shortMs = (longMs ~/ 4).clamp(80, longMs);

    if (detectedClass == 'left' || detectedClass == 'right') {
      if (detectedClass != _lastClass) {
        // 방향이 바뀌었다(또는 첫 경고). 쿨다운을 무시하고 즉시 알린다.
        _lastClass = detectedClass;
        _lastVibratedAt = now;
        return _directionPattern(detectedClass, shortMs, longMs);
      }
      // 같은 방향 지속 — 3초마다 다시 낸다 (음성 재발화와 같은 박자).
      final last = _lastVibratedAt;
      if (last != null && now.difference(last) < repeatInterval) return null;
      _lastVibratedAt = now;
      return _directionPattern(detectedClass, shortMs, longMs);
    }

    if (detectedClass == 'front') {
      // 이탈에서 정상으로 돌아온 순간에만 짧은 확인 진동 1회.
      final returning = _lastClass == 'left' || _lastClass == 'right';
      _lastClass = 'front';
      if (!returning) return null;
      _lastVibratedAt = now;
      return <int>[0, 60];
    }

    // none / approach — 진동 없음. 다만 이탈 상태는 초기화한다.
    _lastClass = detectedClass;
    return null;
  }

  List<int> _directionPattern(String cls, int shortMs, int longMs) {
    // 왼쪽 = 짧게 두 번(..), 오른쪽 = 길게 한 번(—)
    return cls == 'left'
        ? <int>[0, shortMs, shortMs, shortMs]
        : <int>[0, longMs];
  }

  @visibleForTesting
  void reset() {
    _lastClass = null;
    _lastVibratedAt = null;
  }
}
