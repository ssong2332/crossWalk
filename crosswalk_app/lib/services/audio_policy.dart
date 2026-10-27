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

/// T108(사용자 확정 2026-10-12): P0 안의 세부 순위. 앞에 있을수록 높다.
///
/// 10/02 실기기 기록에서 끊긴 안내 35건 중 27건이 이탈 경고와 회복 안내가 서로
/// 끊은 것이었다(둘 다 P0이고 "같은 등급은 나중 것이 이김"). 그래서 P0 안에서도
/// 낮은 순위는 높은 순위를 끊지 못하게 한다.
enum P0Rank {
  /// 외부 위험으로 들어감 ("차도입니다").
  danger,

  /// 이탈 경고 ("오른쪽으로 가세요", "즉시 ...", "... 가장자리입니다").
  deviation,

  /// 회복 확인 ("직진하세요", "그대로 가세요"). 이탈 경고를 끊지 않는다.
  recovery,
}

/// 정책이 내린 결정.
enum SpeechAction {
  /// 지금 발화한다. 재생 중인 것이 있으면 끊는다.
  speakNow,

  /// 대기 슬롯(한 칸)에 넣는다. P1만 쓴다 — 재생 중인 P0·P1이 끝나거나 최소
  /// 간격이 지나면 꺼낸다(T108). TTL(3초)이 지나면 버린다 — T126: 기다리는 동안
  /// P0가 재생됐으면 마지막 P0가 끝난 때부터 센다(상한 [AudioPolicy.maxPendingWait]).
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

  /// T126: 대기 항목이 처음 요청부터 기다릴 수 있는 최대 시간. TTL을 P0가 끝난
  /// 때부터 세므로 P0가 쉬지 않고 이어지면 끝없이 기다릴 수 있어 상한을 둔다.
  /// 근거(추정): 10/24 실기기(`logs/log_20261024_132008-12.jsonl`) P0 뒤에서 만료된
  /// 진입 안내 6건을 이 규칙으로 다시 세면 꺼낼 수 있는 시각(마지막 P0 종료 +
  /// 최소 간격 1.5초)이 요청 뒤 3.0·3.6·4.0·4.6·5.8초, 1건만 11.0초(13:27:39 —
  /// 횡단 약 16초 중 2/3 지점). 8초는 앞 5건을 담고, 1m/s로 약 8m(보통 횡단보도
  /// 절반쯤)다 — 그보다 늦은 "진입했습니다"는 오정보로 본다.
  static const maxPendingWait = Duration(seconds: 8);

  /// T130: 진입 안내("횡단보도 진입.", T134 전 "횡단보도에 진입했습니다.")만 상한을 3초로 줄인다.
  /// 야간 실기기(`logs/log_20261024_191344.jsonl`, `train/field_1024n/report.md`
  /// 추가 확인): 8초 상한 때문에 대기하던 진입 안내 6건이 건넌 순간·뒤에 재생됐다
  /// (지연 4.8~7.5초). 진입은 늦으면 틀린 말이 되지만, 건넜습니다·앞에 횡단보도·
  /// 멈춤 블록은 늦어도 사실이라 [maxPendingWait]를 그대로 둔다.
  static const entryMaxPendingWait = Duration(seconds: 3);

  /// T131: 끼워 넣은 진입 안내([decide]의 `afterP0`)가 재생되는 동안 이탈·회복
  /// P0를 기다리게 하는 최대 시간. 진입 안내는 기본 속도에서 약 2.1초(10/25 기록
  /// `logs/log_20261025_113155.jsonl` 재생 5건 중앙값 2145ms, T134 뒤 "횡단보도 진입."은
  /// 약 1.4초 — 추정)라 보통은 다 말하고
  /// 끝난다. 이 시간이 지나면(느린 속도·TTS 멈춤) P0가 지금처럼 끊는다 — 이탈 경고의
  /// 음성 지연을 3초로 묶는다(진동은 기다리지 않는다).
  static const insertMaxHold = Duration(seconds: 3);

  FeedbackPriority? _active;
  P0Rank? _activeRank;
  String? _activeMessage;
  DateTime? _lastSpeechEnd;
  // T126: 마지막으로 (끊기지 않고) 끝난 P0의 종료 시각 — 대기 항목 TTL의 기준.
  DateTime? _lastP0End;
  // T131: 재생 중인 발화가 P0 뒤에 끼워 넣은 진입 안내면 그 시작 시각.
  DateTime? _insertStartedAt;
  final List<_Span> _spans = <_Span>[];

  /// 대기 슬롯 — 최대 1개. 더 높은 등급이 오면 덮어쓰고, 같은 등급은 대체
  /// (`supersedes`)일 때만 덮어쓴다(T108 — 먼저 온 사실 안내를 지킨다).
  FeedbackPriority? pendingPriority;
  String? pendingMessage;
  DateTime? pendingAt;

  /// T130: 대기 항목의 상한(null이면 [maxPendingWait]).
  Duration? pendingMaxWait;

  FeedbackPriority? get activePriority => _active;

  /// 재생 중인 P0의 세부 순위(P0가 아니면 null).
  P0Rank? get activeRank => _activeRank;

  /// 재생 중인 문구 — 같은 이탈 문구 반복 판단, 연석 겹침(Q3) 판단에 쓴다.
  String? get activeMessage => _activeMessage;

  /// T131: 재생 중인 끼워 넣은 진입 안내의 시작 시각(아니면 null).
  /// T132 ②: 바로 재생된 진입 안내도 같다.
  DateTime? get insertStartedAt => _insertStartedAt;

  /// T108: 최소 간격이 끝나 P1~P3를 다시 말할 수 있는 시각(직전 발화가 없으면 null).
  DateTime? get nextAllowedAt => _lastSpeechEnd?.add(minGap);

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

  /// T106: 직전 [decide]가 그렇게 정한 이유(개발용 기록에만 쓴다 — 판정에는 안 쓴다).
  /// `interrupt_p1`(재생 중인 p1을 끊음) / `wait_p0` / `busy_p0`(더 높은 등급 재생 중이라 버림) /
  /// `p0`(즉시) / `min_gap` / `budget` / `ok`.
  /// T108: `same_p0`(같은 이탈 문구가 재생 중) / `wait_p1`(P1 재생 중이라 대기) /
  /// `supersede_p1`(멈춤 블록을 앞에 횡단보도가 대체) / `gap_p1`(최소 간격이라 대기).
  /// T131: `after_p0`(P0가 끝난 직후 최소 간격 없이 끼워 넣음).
  /// T132 ①: `p0_cut`(P0가 P0에 끊기는 순간 진입 안내를 끼워 넣음).
  String lastReason = '';

  /// docs/AudioPolicy.md §2 판정표. 부수효과가 없으므로 테스트에서 직접 호출해
  /// 전수 검증할 수 있고, `FeedbackService._speak`도 이것만 보고 집행한다.
  /// ([lastReason] 기록만 예외 — 판정 결과에는 영향이 없다.)
  ///
  /// T108: [rank]는 P0의 세부 순위(P0가 아니면 무시), [message]는 같은 이탈 문구
  /// 반복을 가리는 데, [supersedes]는 재생 중인 같은 P1을 대체할 때(Q3) 쓴다.
  /// T131: [afterP0]는 P0가 끝난 직후 끼워 넣는 진입 안내 — 최소 간격을 보지
  /// 않는다(무음 예산은 그대로 본다). 재생 중인 것이 있으면 아무 효과가 없다.
  /// T132 ①: [atP0Cut]은 재생 중인 P0가 다른 P0에 끊기는 순간 끼워 넣는 진입
  /// 안내 — 재생 중인 P0를 끊고 바로 말한다(무음 예산은 본다, `p0_cut`).
  SpeechAction decide(
    FeedbackPriority incoming,
    DateTime now, {
    P0Rank rank = P0Rank.deviation,
    String? message,
    bool supersedes = false,
    bool afterP0 = false,
    bool atP0Cut = false,
  }) {
    final active = _active;

    if (active != null) {
      if (atP0Cut &&
          incoming == FeedbackPriority.p1 &&
          active == FeedbackPriority.p0) {
        if (spokenInWindow(now) >= budgetLimit) {
          lastReason = 'budget';
          return SpeechAction.drop;
        }
        lastReason = 'p0_cut';
        return SpeechAction.speakNow;
      }
      // T108: P0끼리는 세부 순위로 정한다.
      if (incoming == FeedbackPriority.p0 && active == FeedbackPriority.p0) {
        final activeRank = _activeRank ?? P0Rank.deviation;
        if (rank.index > activeRank.index) {
          // 회복 안내는 재생 중인 이탈 경고를 끊지 않는다(Q1).
          lastReason = 'busy_p0';
          return SpeechAction.drop;
        }
        if (rank == activeRank && message != null && message == _activeMessage) {
          // 같은 문구를 다시 끊고 처음부터 말하면 앞부분만 반복해서 들린다.
          lastReason = 'same_p0';
          return SpeechAction.drop;
        }
        lastReason = 'interrupt_p0';
        return SpeechAction.speakNow;
      }
      // P0·P1이 재생 중일 때 들어온 P1은 끊지 않고 기다린다(T108 Q2).
      // 예외: 앞에 횡단보도가 재생 중인 멈춤 블록을 대체(Q3).
      if (incoming == FeedbackPriority.p1 &&
          (active == FeedbackPriority.p0 || active == FeedbackPriority.p1)) {
        if (active == FeedbackPriority.p1 && supersedes) {
          lastReason = 'supersede_p1';
          return SpeechAction.speakNow;
        }
        lastReason = 'wait_${active.name}';
        return SpeechAction.queue;
      }
      // 더 높은 등급(index가 작음) 또는 같은 등급 -> 끊고 교체.
      if (incoming.index <= active.index) {
        lastReason = 'interrupt_${active.name}';
        return SpeechAction.speakNow;
      }
      lastReason = 'busy_${active.name}';
      return SpeechAction.drop;
    }

    // 재생 중인 것이 없다. P0는 예산·간격을 무시하고 즉시 나간다.
    if (incoming == FeedbackPriority.p0) {
      lastReason = 'p0';
      return SpeechAction.speakNow;
    }

    final last = _lastSpeechEnd;
    final skipGap = afterP0 && incoming == FeedbackPriority.p1;
    if (!skipGap && last != null && now.difference(last) < minGap) {
      // T108 Q2: 1회성 사실 안내(P1)는 버리지 않고 간격이 끝날 때까지 기다린다.
      if (incoming == FeedbackPriority.p1) {
        lastReason = 'gap_p1';
        return SpeechAction.queue;
      }
      lastReason = 'min_gap';
      return SpeechAction.drop;
    }
    if (spokenInWindow(now) >= budgetLimit) {
      lastReason = 'budget';
      return SpeechAction.drop;
    }
    lastReason = skipGap ? 'after_p0' : 'ok';
    return SpeechAction.speakNow;
  }

  /// T131: 끼워 넣은 진입 안내가 재생 중이라 이 P0를 끊지 말고 기다리게 하는가.
  /// 차도(danger)는 기다리지 않는다. [insertMaxHold]가 지나면 기다리지 않는다.
  bool holdsP0ForInsert(P0Rank rank, DateTime now) {
    final at = _insertStartedAt;
    return at != null &&
        _active == FeedbackPriority.p1 &&
        rank != P0Rank.danger &&
        now.difference(at) < insertMaxHold;
  }

  /// TTL이 지났는지. 대기 슬롯에서 꺼낼 때와 요청 시점 모두에서 쓴다.
  bool isExpired(FeedbackPriority priority, DateTime requestedAt, DateTime now) {
    final limit = ttl[priority] ?? Duration.zero;
    return now.difference(requestedAt) > limit;
  }

  /// T131: [insertedAt]은 P0 뒤에 끼워 넣은 진입 안내일 때 그 시작 시각.
  void markStarted(FeedbackPriority priority,
      {P0Rank rank = P0Rank.deviation, String? message, DateTime? insertedAt}) {
    _active = priority;
    _activeRank = priority == FeedbackPriority.p0 ? rank : null;
    _activeMessage = message;
    _insertStartedAt = insertedAt;
  }

  /// 발화가 끝났을 때 호출. P0는 예산에 누적하지 않는다(§4).
  ///
  /// T108: [current]가 false면 다른 발화에 끊겨 끝난 것이다. 이때는 이미 새
  /// 발화가 재생 중이므로 '재생 중' 상태와 마지막 종료 시각을 건드리지 않는다
  /// (예산 누적만 한다). T108 전에는 같은 등급끼리 끊으면 끊긴 쪽의 마무리가
  /// 새 발화의 '재생 중' 상태를 지워, 정책이 재생 중인 이탈 경고를 못 봤다.
  void markFinished(FeedbackPriority priority, DateTime start, DateTime end,
      {bool current = true}) {
    if (current && _active == priority) {
      _active = null;
      _activeRank = null;
      _activeMessage = null;
      _insertStartedAt = null;
    }
    if (current) _lastSpeechEnd = end;
    if (current && priority == FeedbackPriority.p0) _lastP0End = end;
    if (priority != FeedbackPriority.p0) {
      _spans.add(_Span(start, end));
      final cutoff = end.subtract(budgetWindow);
      _spans.removeWhere((s) => s.end.isBefore(cutoff));
    }
  }

  /// 대기 슬롯에 넣는다. 넣었으면 true, 슬롯을 지키느라 버렸으면 false.
  ///
  /// 더 높은 등급만 덮어쓴다. 같은 등급은 [supersedes](Q3: 앞에 횡단보도가 멈춤
  /// 블록을 대체)일 때만 덮어쓴다 — T108 전에는 같은 등급도 덮어써서 먼저 온
  /// "횡단보도를 건넜습니다"가 뒤에 온 안내에 밀려 사라질 수 있었다.
  /// [requestedAt]은 처음 요청 시각이다(TTL은 여기서부터 센다).
  /// [maxWait]는 이 항목의 상한(T130, null이면 [maxPendingWait]).
  bool putPending(FeedbackPriority priority, String message, DateTime requestedAt,
      {bool supersedes = false, Duration? maxWait}) {
    final cur = pendingPriority;
    if (cur != null &&
        (priority.index > cur.index || (priority == cur && !supersedes))) {
      return false;
    }
    pendingPriority = priority;
    pendingMessage = message;
    pendingAt = requestedAt;
    pendingMaxWait = maxWait;
    return true;
  }

  /// T126: 대기 항목이 만료됐으면 그 이유(`ttl` / `max_wait`), 아니면 null.
  ///
  /// 10/24 실기기: 진입 안내 12건 중 6건이 진입과 함께 시작된 이탈 경고(P0) 뒤에서
  /// 기다리다 처음 요청부터 센 TTL 3초로 버려졌다. 그래서 TTL은 처음 요청과 그
  /// 뒤에 끝난 마지막 P0 종료 중 늦은 쪽부터 센다. P0가 재생 중인 동안은 TTL이
  /// 흐르지 않는다(상한 [maxPendingWait]만 본다). P1 재생·최소 간격 대기는 전과
  /// 같다(처음 요청부터).
  String? pendingExpiry(DateTime now) {
    final pri = pendingPriority;
    final at = pendingAt;
    if (pri == null || at == null) return null;
    if (now.difference(at) > (pendingMaxWait ?? maxPendingWait)) {
      return 'max_wait';
    }
    if (_active == FeedbackPriority.p0) return null;
    final p0End = _lastP0End;
    final from = p0End != null && p0End.isAfter(at) ? p0End : at;
    return isExpired(pri, from, now) ? 'ttl' : null;
  }

  /// 대기 항목이 만료됐으면([pendingExpiry]) 비우고 그 문구를 돌려준다. 없거나
  /// 아직 유효하면 null.
  ///
  /// TTL은 꺼낼 때(`_drainPending`)만 확인됐다. P0가 쉬지 않고 이어지면 꺼낼
  /// 기회가 없어, 이미 만료된 항목이 슬롯을 지키며 새 P1을 `slot_full`로 버렸다
  /// (10/12 기록 L1929 "진입했습니다" 대기 -> L2066 "건넜습니다" 버림, 7.7초 전
  /// 만료). 넣기 전에 이것을 불러 죽은 항목을 치운다.
  String? takeExpiredPending(DateTime now) {
    if (pendingExpiry(now) == null) return null;
    final msg = pendingMessage;
    clearPending();
    return msg;
  }

  void clearPending() {
    pendingPriority = null;
    pendingMessage = null;
    pendingAt = null;
    pendingMaxWait = null;
  }

  @visibleForTesting
  void reset() {
    _active = null;
    _activeRank = null;
    _activeMessage = null;
    _lastSpeechEnd = null;
    _lastP0End = null;
    _insertStartedAt = null;
    _spans.clear();
    clearPending();
  }
}

/// 진동 정책 — docs/AudioPolicy.md §5.
///
/// 좌/우가 같은 패턴이던 것을 분리한다. 도로 소음에 음성이 묻혀도 방향이 전달되도록,
/// 그리고 같은 방향이 지속될 때 음성 대신 진동만으로 알리기 위해서다.
/// T136(사용자 승인, 2026-10-26): 좌우를 다시 같은 패턴(짧게 1번)으로 — 방향은 음성으로만,
/// 진동은 이탈 정도(반복 간격)를 전한다.
class VibrationPolicy {
  /// 같은 방향이 계속될 때 방향 패턴을 다시 내는 간격(이탈 단계 보통 = 0).
  ///
  /// T136(사용자 승인, 2026-10-26 실기기): 3초 → 1초. T139(2026-10-27): 1초 → 0.6초.
  /// 초판의 간격 점증(1->2->4->8초)은 제거했다: 진동이 8초 간격이면 음성만 나가고
  /// 진동은 없는 구간이 생긴다.
  static const repeatInterval = Duration(milliseconds: 600);

  /// T132 ④(사용자 선택 A, 2026-10-25): 이탈 단계(`FeedbackService.deviationLevel`)별
  /// 같은 방향 반복 간격. 매 프레임 지금 단계의 간격으로 마지막 진동부터 잰다:
  /// 단계가 오르면 그 간격이 이미 지났을 때 바로 내고, 내려가면 바로 느려진다.
  /// 음성 6초 묶음(T120)과는 별개다.
  ///
  /// T136(사용자 승인, 2026-10-26 실기기 "빨라지는 건 느껴지지만 더 빨라야"):
  /// 보통 3초→1초, 즉시 1.5초→0.6초, 가장자리 1초→0.4초.
  /// T139(사용자 승인, 2026-10-27 실기기 "경고성 알림이니 1.5~2배 빠르게"):
  /// 보통 1초→0.6초, 즉시 0.6초→0.35초, 가장자리 0.4초→0.25초. 250ms 간격에서
  /// 150ms 진동이 끊겨 느껴지는지는 실기기 확인 항목(추정).
  static const repeatIntervalsByLevel = <Duration>[
    repeatInterval,
    Duration(milliseconds: 350),
    Duration(milliseconds: 250),
  ];

  /// T136: 방향 진동 한 번의 길이 — 좌우 같게 짧게 1번. 가장 짧은 반복 간격
  /// (가장자리 250ms, T139)보다 반드시 짧아야 진동이 이어 붙지 않는다. 방향은 음성으로만
  /// 전달한다(하드웨어 기기로 가면 좌우 모터 2개로 나눌 계획).
  static const directionPulseMs = 150;

  /// T132 ④: [level]의 반복 간격. 범위 밖이면 가까운 끝 값.
  static Duration repeatIntervalFor(int level) =>
      repeatIntervalsByLevel[level.clamp(0, repeatIntervalsByLevel.length - 1)];

  String? _lastClass;
  DateTime? _lastVibratedAt;
  int _lastLevel = 0;

  String? get lastClass => _lastClass;

  /// T132 ④: 마지막 [decidePattern] 호출의 이탈 단계와 그 반복 간격(기록용).
  int get lastLevel => _lastLevel;
  Duration get lastInterval => repeatIntervalFor(_lastLevel);

  /// `Vibration.vibrate(pattern:)`에 넣을 패턴을 돌려준다. null이면 진동하지 않는다.
  ///
  /// [longMs]는 사용자가 설정에서 조정하는 진동 길이다. T136부터 방향 진동은
  /// [directionPulseMs]로 고정이라 이 값을 쓰지 않는다(호출부 호환으로 남김).
  ///
  /// T132 ④: [level]은 이번 프레임의 이탈 단계(0 보통·1 즉시·2 가장자리) —
  /// 같은 방향 반복 간격을 정한다([repeatIntervalFor]).
  List<int>? decidePattern(String detectedClass, DateTime now, int longMs,
      {int level = 0}) {
    _lastLevel = level;

    if (detectedClass == 'left' || detectedClass == 'right') {
      if (detectedClass != _lastClass) {
        // 방향이 바뀌었다(또는 첫 경고). 쿨다운을 무시하고 즉시 알린다.
        _lastClass = detectedClass;
        _lastVibratedAt = now;
        return directionPattern;
      }
      // 같은 방향 지속 — 지금 단계의 간격마다 다시 낸다(T132 ④).
      final last = _lastVibratedAt;
      if (last != null && now.difference(last) < repeatIntervalFor(level)) {
        return null;
      }
      _lastVibratedAt = now;
      return directionPattern;
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

  /// T136(사용자 승인): 좌우 같은 패턴 — 짧게 1번([directionPulseMs]).
  /// 종전(T61)은 왼쪽 짧게 2번·오른쪽 길게 1번이었다.
  static const directionPattern = <int>[0, directionPulseMs];

  @visibleForTesting
  void reset() {
    _lastClass = null;
    _lastVibratedAt = null;
    _lastLevel = 0;
  }
}
