import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:vibration/vibration.dart';
import '../localization/app_strings.dart';
import 'audio_policy.dart';
import 'event_log.dart';
import 'severity_latch.dart';
import 'stillness_detector.dart';
import 'surface_guide.dart';

/// T108 Q1: 보류한 회복 안내를 어떻게 할지([FeedbackService.decideHeldRecovery]).
enum HeldRecoveryVerdict { wait, speak, cancel, expire }

class FeedbackService {
  final FlutterTts _tts = FlutterTts();

  // T61: 오디오 우선순위 정책 (docs/AudioPolicy.md). 판정 로직은 플러그인에
  // 의존하지 않는 순수 클래스로 분리해 두었다 — 이 파일은 "지금 말해도 되는가"를
  // 물어보기만 한다. 이 파일의 경쟁 상태 보증(_speechGeneration, _vibrationTimer)은
  // 그대로 유지된다.
  @visibleForTesting
  final AudioPolicy audioPolicy = AudioPolicy();
  @visibleForTesting
  final VibrationPolicy vibrationPolicy = VibrationPolicy();

  /// T82: 이탈 강도가 프레임마다 뒤집혀 음성·진동이 반복되는 것을 막는다.
  /// 화면(`camera_screen.dart`의 `_severe`)도 같은 값을 읽어, 문구·색과
  /// 소리가 서로 다른 강도를 말하는 일이 없게 한다.
  @visibleForTesting
  final SeverityLatch severityLatch = SeverityLatch();

  /// T133: 가속도로 판단한 '서 있음'. 서 있으면 같은 방향 음성 반복을 멈춘다
  /// ([decideMessage]). 표본은 `CameraScreen`이 [addAccelerometer]로 넣는다.
  @visibleForTesting
  final StillnessDetector stillness = StillnessDetector();

  /// T133: 가속도 표본 하나(m/s², 중력 포함). 서 있음이 바뀌면 `still`을 남긴다.
  void addAccelerometer(double x, double y, double z, DateTime now) {
    if (!stillness.add(x, y, z, now)) return;
    final mot = stillness.motion;
    EventLog.instance.log('still', {
      'on': stillness.isStill,
      if (mot != null) 'mot': double.parse(mot.toStringAsFixed(3)),
    });
    // T136(사용자 승인 A안): 좌우 진동이 같아 서 있는 동안 방향을 알 수 없다.
    // 걸음을 뗄 때 이탈이 이어지고 있으면 다음 판정에서 방향 경고를 한 번 말한다.
    final raw = _lastRawClass;
    _stillOffPending =
        !stillness.isStill && (raw == 'left' || raw == 'right');
  }

  /// T136: 서 있음이 풀린 순간 이탈(left/right) 중이었다 — 다음 [decideMessage]
  /// 한 번에만 쓰고 비운다. 그 판정이 같은 방향이면 T120 6초 묶음에 막히지 않고
  /// 말한다(`say.force` why=still_off).
  bool _stillOffPending = false;

  /// 화면 표시용 — 지금 보고 중인 이탈 강도.
  bool get isSevere => severityLatch.isSevere;

  /// T84: '크게 벗어남' 판정 각도(도). 이 값 이상 틀어지면 심함.
  /// 근거(누수 없는 CV, left/right 354장, 정답=|기하각도|>=30):
  ///   20도 재현율 89%/정밀도 90%, **25도 82%/92%**, 30도 72%/94%.
  /// 25는 사용자가 고른 균형점(2026-09-13). 실기기 결과에 따라 여기만 바꾼다.
  static const double severeAngleDegrees = 25.0;

  DateTime? _lastAlertTime;
  String? _lastAlertClass;
  // T120(사용자 확정 2026-10-20): 마지막으로 **말한** 이탈 경고의 단계
  // ([deviationLevel]). 같은 방향이면 이 값보다 올라갈 때만 6초 묶음을 깬다.
  int? _lastAlertLevel;

  /// T132 ④: 이번 프레임의 이탈 단계([deviationLevel]) — 말했는지와 무관하게
  /// [decideMessage]가 정한 값. left/right가 아니면 null. 진동 반복 간격에 쓴다.
  int? _frameDeviationLevel;

  /// T120: 같은 방향 이탈 경고 묶음 창. 마지막으로 말한 뒤 이 안에서는 단계가
  /// 같거나 내려가면(문장만 바뀐 경우 포함) 말하지 않는다(진동은 그대로).
  /// 근거: `train/audio_occupancy/report.md` §3·§5 B — 기록 재계산(추정).
  static const sameDirectionBundle = Duration(seconds: 6);

  /// T120: 묶음으로 말하지 않은 경고를 `say.cancel`(why=same_dir)로 남기는 기준.
  /// 종전 쿨다운(3초·단계/끝 여부가 바뀌면 다시 말함)이었다면 말했을 때만 남긴다
  /// — 프레임마다 남기면 기록이 넘친다.
  DateTime? _bundleLogAt;
  String? _bundleLogText;

  /// T120: front가 이어지기 시작한 시각. [recoveryHold] 이상 이어지면 회복으로
  /// 보고 묶음을 푼다(그 뒤 이탈은 새 이탈 — 바로 말함).
  DateTime? _frontSince;

  /// T120: 이탈 경고 단계 — 가장자리 2 > 즉시(심함) 1 > 보통 0.
  /// [decideMessage]가 문장을 고르는 순서 그대로다(사용자 확정 2026-10-20).
  @visibleForTesting
  static int deviationLevel({required bool severe, required bool atEdge}) =>
      atEdge ? 2 : (severe ? 1 : 0);

  /// T124(사용자 확정 2026-10-21): 직전 [decideMessage]가 '빠른 상승' 문장을 골랐는가.
  /// 빠른 상승 = 앞 이탈 경고가 아직 재생 중인데 같은 방향 단계가 오름(T3).
  /// 그때는 짧은 문장(`…RapidMessage`)을 사용자 속도의 [rapidRateFactor]배로 말한다.
  bool _lastDecisionRapid = false;
  @visibleForTesting
  bool get lastDecisionRapid => _lastDecisionRapid;

  /// T124: 빠른 상승 문장의 속도 배율과 상한(설정 슬라이더 최댓값,
  /// `settings_screen.dart`의 TTS 속도 Slider max).
  static const rapidRateFactor = 1.2;
  static const maxSpeechRate = 1.0;

  /// T124: 빠른 상승 문장의 속도 — 사용자 설정 × 1.2, 설정 범위 상한 안.
  @visibleForTesting
  static double rapidRate(double userRate) {
    final r = userRate * rapidRateFactor;
    return r > maxSpeechRate ? maxSpeechRate : r;
  }

  /// T124: 플러그인에 마지막으로 보낸 속도. 발화마다 자기 속도(빠른 상승이면
  /// [rapidRate], 아니면 사용자 설정)와 다르면 먼저 바꾼다 — 그래서 다음 발화에서
  /// 저절로 원래 속도로 돌아간다. null이면 아직 보낸 적 없음(사용자 설정으로 본다).
  double? _appliedRate;

  // T63: 매 alert() 호출마다(메시지가 실제로 나갔는지와 무관하게) 갱신되는
  // "직전 판정 클래스". 구간 전이(진입/이탈 완료/복귀)를 감지하려면 발화
  // 여부와 무관하게 진짜 이전 프레임의 클래스를 알아야 한다 — _lastAlertClass는
  // 쿨다운에 걸려 갱신이 안 될 수 있어 이 목적에 쓸 수 없다.
  String? _lastRawClass;

  /// T82: [severityLatch]를 언제 초기화할지 판단하기 위한 직전 이탈 방향.
  /// `_lastRawClass`는 `alert()`가 `decideMessage()`를 부르기 전에 이미
  /// 현재 클래스로 덮어써서 이 목적에 쓸 수 없다.
  String? _lastSeverityClass;

  /// T123(사용자 결정 2026-10-21): 진행 안내 3초 재쿨다운은 **같은 문장끼리만** 건다.
  /// 전에는 공통 하나라서 "앞에 횡단보도" 뒤 0.87~2.87초 만에 위로 들어오면
  /// "진입했습니다"가 요청조차 되지 않았다(10/21 기록, 10번 중 8번).
  final Map<String, DateTime> _lastPhaseAt = {};

  /// T118: "발밑이 인도"라서 hold를 일찍 푼 시각. 이 뒤 [groundReleaseCrossedWindow]
  /// 안에 crossed가 오면 none/approach -> crossed여도 "건넜습니다"를 낸다(A2).
  DateTime? _holdReleasedByGroundAt;

  /// T118 보완: 위에서 푼 hold가 시작된 시각. 일찍 풀지 않았다면 hold 시작부터
  /// `CrossingHold.holdDuration`(10초) 안의 crossed는 "건넜습니다"였다 — 그 창을 지킨다.
  DateTime? _releasedHoldStartedAt;

  /// T118: 위 창(추정값). 도착 연석에서 crossed 판정까지 10/02 기록 L1051은 3.5초.
  static const groundReleaseCrossedWindow = Duration(seconds: 5);

  /// T118 보완: hold 시작부터의 창 — `CrossingHold.holdDuration`과 같은 10초.
  static const holdStartCrossedWindow = Duration(seconds: 10);

  /// T118: `CrossingHold`가 발밑이 인도라서 hold를 푼 직후 부른다.
  /// [holdStartedAt]은 그 hold가 시작된 시각(`CrossingHold.releasedHoldStartedAt`).
  void noteHoldReleasedByGround(DateTime now, {DateTime? holdStartedAt}) {
    _holdReleasedByGroundAt = now;
    _releasedHoldStartedAt = holdStartedAt;
  }

  /// T118 보완: 일찍 푼 뒤 crossed를 "건넜습니다"로 볼 마지막 시각 —
  /// hold 시작 + 10초와 해제 + 5초 중 늦은 쪽.
  @visibleForTesting
  static DateTime groundReleaseCrossedUntil(
      DateTime releasedAt, DateTime? holdStartedAt) {
    final afterRelease = releasedAt.add(groundReleaseCrossedWindow);
    if (holdStartedAt == null) return afterRelease;
    final afterStart = holdStartedAt.add(holdStartCrossedWindow);
    return afterStart.isAfter(afterRelease) ? afterStart : afterRelease;
  }
  DateTime? _lastRecoveryAt;

  // T102: 직전 alert()가 "끝 + 이미 중앙 쪽으로 틀었음(front)"이었는가.
  bool _lastEdgeTurned = false;
  DateTime? _lastEdgeTurnedAt;

  // T108 Q1(사용자 확정 2026-10-12): 회복 안내("직진하세요"/"그대로 가세요")는
  // 바로 말하지 않고 보류했다가, front가 [recoveryHold] 동안 유지되면 말한다.
  // 10/02 기록에서 끊긴 안내 35건 중 27건이 이탈↔회복이 0.7~1초 안에 서로 끊은
  // 것이었다(상태 깜빡임). 확인 진동은 지금처럼 즉시 나간다.
  String? _heldRecovery;
  DateTime? _heldRecoveryAt;
  bool _heldRecoveryIsEdge = false;

  /// 회복 안내를 말하기 전 front가 유지돼야 하는 시간(추정값, 실기기로 조정).
  static const recoveryHold = Duration(milliseconds: 700);

  /// 유지 확인 뒤 이탈 경고가 재생 중이면 기다리는 최대 시간(추정값).
  static const recoveryMaxWait = Duration(seconds: 2);

  // T108 Q2: 대기 슬롯의 P1을 최소 간격이 끝나는 시각에 꺼내는 타이머.
  Timer? _drainTimer;

  // T131: 끼워 넣은 진입 안내가 재생되는 동안 기다리게 한 P0(최신 1개).
  String? _insertHeld;
  P0Rank _insertHeldRank = P0Rank.deviation;
  double? _insertHeldRate;
  String _insertHeldClass = '';
  Timer? _insertHoldTimer;

  /// T118: 대기 꺼내기 타이머 여유. 타이머는 ms로 잘려 예약되는데 간격 판정은
  /// µs 시각을 써서, 몇 µs 일찍 울리면 "아직 간격 안"으로 다시 대기하고 곧바로
  /// 또 울리기를 반복했다(10/19 기록 L3471~L3484, 같은 ms에 14번).
  static const drainMargin = Duration(milliseconds: 20);

  /// T118: 간격이 끝나는 [allowed]까지 남은 시간 + [drainMargin].
  @visibleForTesting
  static Duration drainDelay(DateTime? allowed, DateTime now) =>
      (allowed == null || !allowed.isAfter(now)
          ? Duration.zero
          : allowed.difference(now)) +
      drainMargin;

  /// T118(사용자 확정 A, 2026-10-20): 횡단보도 없음 상태의 "멈춤 블록입니다"는
  /// 잠깐 보류한다. 그사이 "앞에 횡단보도"가 나오면 그것만 말한다.
  /// 기록 17건 중 블록 뒤 앞에 횡단보도가 온 7건이 모두 1.25초 안이었다.
  static const dotBlockHold = Duration(milliseconds: 1300);
  Timer? _dotBlockTimer;
  DateTime? _heldDotBlockAt;

  /// T118: 직전 상태 [lastClass]에서 멈춤 블록을 보류하는가. 횡단보도 없음(none·
  /// 콜드스타트)에서만 — 건넌 직후(crossed)·위·앞은 지금처럼 바로 처리한다.
  @visibleForTesting
  static bool holdsDotBlock(String lastClass) =>
      lastClass == 'none' || lastClass == '';

  void _holdDotBlock(String message, DateTime now) {
    _dotBlockTimer?.cancel();
    _heldDotBlockAt = now;
    EventLog.instance.log('say.defer', {'text': message});
    _dotBlockTimer = Timer(dotBlockHold, () {
      final at = _heldDotBlockAt;
      _heldDotBlockAt = null;
      if (at == null) return;
      // T118 보완: 보류하는 동안 횡단보도 위·앞 등으로 바뀌었으면 말하지 않는다.
      if (!holdsDotBlock(_lastRawClass ?? '')) {
        EventLog.instance.log('say.cancel', {'text': message, 'why': 'state'});
        return;
      }
      unawaited(_speak(message,
          priority: FeedbackPriority.p1, requestedAt: at));
    });
  }

  // T38 fix: guards against isSpeaking/isVibrating being reset by a stale
  // await/timer from an earlier alert() call. decideMessage() bypasses
  // the cooldown on a class change, so alert() can be invoked again before
  // the previous call's 500ms vibration timer or `await _tts.speak()` has
  // resolved. Each call captures the generation/timer that was current *at
  // the time it started*; a reset is only honored if nothing newer has
  // started since, and a new vibration timer always cancels the previous
  // one first.
  int _speechGeneration = 0;
  Timer? _vibrationTimer;

  // Defaults to Korean so behavior is unchanged for callers/tests that
  // never call init() (matches this app's pre-localization fallback).
  AppLanguage _language = AppLanguage.ko;

  // T39: previously hardcoded (`setSpeechRate(0.5)` / `_vibrationDurationMs`
  // was a `static const 500`). Now mutable instance fields with the same
  // defaults, so SettingsScreen can read the current value to initialize
  // its sliders and change it at runtime via updateSpeechRate()/
  // updateVibrationDuration() below. Session-only — no persistence.
  double _speechRate = 0.5;
  int _vibrationDurationMs = 500;

  AppLanguage get language => _language;
  double get speechRate => _speechRate;
  int get vibrationDurationMs => _vibrationDurationMs;

  static const _cooldownSeconds = 3;

  // T38: exposes whether TTS speech / vibration are currently active, so
  // the UI can show "음성 재생 중 / 진동 중" indicator pills. Read-only
  // ValueNotifiers (flutter/foundation, not a widget import) keep the
  // service framework-light per docs/Architecture.md §13 while letting
  // CameraScreen react without polling.
  final ValueNotifier<bool> isSpeaking = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isVibrating = ValueNotifier<bool>(false);

  Future<void> init({AppLanguage language = AppLanguage.ko}) async {
    _language = language;
    await _tts.setLanguage(ttsLocaleCode(_language));
    _appliedRate = _speechRate;
    await _tts.setSpeechRate(_speechRate);
    await _tts.setVolume(1.0);

    // T38 redesign: `isSpeaking` is now driven purely by awaiting
    // `_tts.speak()` itself (see _speak() below) instead of
    // setCompletionHandler/setCancelHandler/setErrorHandler callbacks.
    // Those callbacks were removed because flutter_tts's Android plugin
    // delivers "speak.onCancel" via `handler.post {}` (a queued main-thread
    // dispatch) with no utterance/generation id, so its arrival could race
    // against this service's own generation rebinding regardless of
    // handler bind order (flutter_tts-4.2.5
    // android/.../FlutterTtsPlugin.kt:142, `handler.post` at :203).
    //
    // awaitSpeakCompletion(true) makes `_tts.speak()`'s Future resolve only
    // when the native side calls back that specific MethodChannel
    // invocation's Result — verified directly in flutter_tts-4.2.5 source:
    //   - Android: `speak` handler stores the invoking `Result` in
    //     `speakResult` (FlutterTtsPlugin.kt:320-325, gated on
    //     `queueMode == TextToSpeech.QUEUE_FLUSH`, which is the plugin's
    //     default per FlutterTtsPlugin.kt:55). `stop` synchronously
    //     resolves any pending `speakResult` with `success(0)`
    //     (FlutterTtsPlugin.kt:379-382) as part of handling the "stop"
    //     method call itself — not via the async utterance-progress
    //     listener — so awaiting `_tts.stop()` before the next `speak()`
    //     cannot be left hanging by native event timing.
    //   - iOS: `speak()` stores `result` in `speakResult`
    //     (SwiftFlutterTtsPlugin.swift:142-146,162-166) and it is resolved
    //     in `didFinish` (:441-444). NOTE (verified, not acted on): iOS's
    //     `didCancel` delegate does NOT resolve `speakResult`
    //     (SwiftFlutterTtsPlugin.swift:464-466 only forwards
    //     "speak.onCancel"), so a `stop()` that interrupts an in-flight
    //     `awaitSpeakCompletion` speak() could leave that Future pending
    //     indefinitely on iOS. Not a regression introduced here (iOS is
    //     unconfirmed for this app per docs/Architecture.md) but flagged
    //     for anyone enabling iOS.
    //
    // Because each `_tts.speak()` call gets its own dedicated Result tied
    // to that specific platform-channel invocation, there is no shared
    // callback state a stale event could land on — eliminating the race at
    // the platform-channel level rather than only working around it.
    await _tts.awaitSpeakCompletion(true);
  }

  // T63: 쿨다운 키가 (클래스, 강도) 쌍으로 바뀌었다 — 방향이 그대로여도
  // 강도가 바뀌면(약함<->심함) 즉시 재발화한다.
  // T120: 지금은 **올라갈 때만** 즉시 재발화하고, 같거나 내려가면 6초 묶음이다
  // ([sameDirectionBundle], [deviationLevel]).
  //
  // T84(2026-09-13): 강도의 입력을 **분류기 신뢰도에서 각도 모델 출력으로**
  // 바꿨다. 사용자 실기기 스크린샷 27장에서 "18도인데 크게 벗어남, 32도인데
  // 틀어짐"처럼 각도와 강도가 따로 놀았다. 누수 없는 CV(left/right 354장)로
  // 재보니 신뢰도>=0.80은 정판정 이탈의 81%를 '심함'으로 찍어 사실상 항상
  // 심함이었고(|기하각도|>=30 판별 정밀도 89% = 기저율 89%), 변별력이 없었다.
  // |각도|>=25는 같은 정답에 재현율 82% / 정밀도 92%다.
  // 주의: 각도로도 **위치(가장자리)** 는 판별할 수 없다(정밀도 4% = 기저율).
  // 그래서 '크게 벗어남'의 정의는 "많이 틀어졌다"다(사용자 확정, 2026-09-13).
  //
  // T82(2026-09-08): 그 "강도"를 **신뢰도와 직접 비교하지 않고**
  // [SeverityLatch]를 거친 값으로 바꿨다. 사용자가 실기기에서 "가만히 서
  // 있는데 '크게 벗어남'과 '이탈'이 번갈아 나오고 그때마다 음성·진동이 다시
  // 나온다"고 보고했는데, 원인이 바로 이 쿨다운 키였다 — 신뢰도가 0.80 근처를
  // 오가면 강도가 뒤집히고, 쿨다운이 무효화되어 즉시 재발화한다.
  // 실측(같은 세션 5초 이내 연속쌍 46쌍): 같은 방향인데 강도가 뒤집힌 경우가
  // 11쌍(23.9%)이고 변화폭이 0.98->0.68처럼 컸다. 래치를 거치면 그 변화가
  // 2초 이상 유지될 때만 강도가 바뀌므로, 튀었다 되돌아오는 경우는 쿨다운을
  // 무효화하지 못한다. 진짜로 악화된 경우(2초 이상 유지)는 종전대로 즉시
  // 재발화한다 — 안전 쪽 동작은 유지된다.
  /// [angleDegrees]는 화살표가 쓰는 것과 같은 보정 각도(`_arrowStripeAngle`)다
  /// — 화면·화살표·음성이 같은 값을 보게 하려는 것. null(각도 모델 미준비·
  /// 미검출)이면 보수적으로 약함으로 본다.
  @visibleForTesting
  ///
  /// T102: [atEdge]면(끝 규칙이 낸 left/right) 강도와 무관하게 끝 전용 문구
  /// ("오른쪽으로 가세요. 가장자리입니다")를 낸다. 끝 각도는 ±20으로
  /// 고정돼 심함(25) 기준에 닿지 않으므로 "즉시" 변형은 없다.
  String? decideMessage(
      String detectedClass, double? angleDegrees, DateTime now,
      {bool atEdge = false}) {
    final stillOff = _stillOffPending;
    _stillOffPending = false;
    if (detectedClass != 'left' && detectedClass != 'right') {
      severityLatch.reset();
      _lastSeverityClass = null;
      _frameDeviationLevel = null;
      // T120: front가 [recoveryHold] 이상 이어지면 회복 — 묶음을 푼다. 더 짧은
      // front 깜빡임과 none·approach·crossed는 회복이 아니다(묶음 유지).
      if (detectedClass == 'front') {
        _frontSince ??= now;
        if (now.difference(_frontSince!) >= recoveryHold) {
          _lastAlertTime = null;
          _lastAlertClass = null;
          _lastAlertLevel = null;
        }
      } else {
        _frontSince = null;
      }
      return null;
    }
    _frontSince = null;
    // 방향이 바뀌면 강도는 처음부터 다시 판단한다(왼쪽에서 심했다고 오른쪽도
    // 심한 것은 아니다). `_lastRawClass`는 alert()가 decideMessage를 부르기
    // **전에** 이미 현재 클래스로 덮어쓰므로 여기서는 쓸 수 없다 — 이 목적의
    // 전용 필드를 따로 둔다.
    if (_lastSeverityClass != null && _lastSeverityClass != detectedClass) {
      severityLatch.reset();
    }
    _lastSeverityClass = detectedClass;

    final severe = severityLatch.update(
        angleDegrees != null && angleDegrees.abs() >= severeAngleDegrees, now);
    final level = deviationLevel(severe: severe, atEdge: atEdge);
    _frameDeviationLevel = level;
    final strings = AppStrings.of(_language);
    // T124: 빠른 상승(T3) — 같은 방향 단계가 올랐고, 앞 이탈 경고가 아직 재생 중.
    final deviationPlaying =
        audioPolicy.activePriority == FeedbackPriority.p0 &&
            (audioPolicy.activeRank ?? P0Rank.deviation) == P0Rank.deviation;
    final rapid = _lastAlertTime != null &&
        _lastAlertClass == detectedClass &&
        level > _lastAlertLevel! &&
        deviationPlaying;
    _lastDecisionRapid = false;
    final String message;
    if (rapid) {
      message = atEdge
          ? (detectedClass == 'left'
              ? strings.leftEdgeRapidMessage
              : strings.rightEdgeRapidMessage)
          : (detectedClass == 'left'
              ? strings.leftSevereRapidMessage
              : strings.rightSevereRapidMessage);
    } else if (atEdge) {
      message = detectedClass == 'left'
          ? strings.leftEdgeMessage
          : strings.rightEdgeMessage;
    } else if (detectedClass == 'left') {
      message = severe
          ? strings.leftDeviationMessageSevere
          : strings.leftDeviationMessageMild;
    } else {
      message = severe
          ? strings.rightDeviationMessageSevere
          : strings.rightDeviationMessageMild;
    }

    // T120(사용자 확정 2026-10-20): 같은 방향이면 마지막으로 말한 단계와 비교한다.
    // 6초 안에 같거나 내려가면 묶는다(진동은 그대로). 올라가면 바로 말한다.
    // 방향이 바뀌면(_lastAlertClass가 다름) 종전대로 바로 말한다.
    // T136(사용자 승인 A안): 서 있음이 풀린 직후의 첫 판정이 같은 방향이면
    // 묶음·서 있음 생략 없이 한 번 말한다 — 서 있는 동안엔 진동만 받아 방향을 모른다.
    final sameDirRepeat = _lastAlertTime != null &&
        _lastAlertClass == detectedClass &&
        level <= _lastAlertLevel!;
    if (stillOff && sameDirRepeat) {
      EventLog.instance
          .log('say.force', {'text': message, 'why': 'still_off'});
    } else if (sameDirRepeat &&
        now.difference(_lastAlertTime!) < sameDirectionBundle) {
      if (_bundleLogText != message ||
          now.difference(_bundleLogAt!).inSeconds >= _cooldownSeconds) {
        _bundleLogAt = now;
        _bundleLogText = message;
        EventLog.instance
            .log('say.cancel', {'text': message, 'why': 'same_dir'});
      }
      return null;
    }

    // T133(사용자 승인 안 A, 2026-10-25): 서 있으면 같은 방향 반복(6초 재경고,
    // 단계가 같거나 내려감)은 말하지 않는다 — 진동은 그대로(T132 ④ 박자).
    // 첫 경고·방향 바뀜·단계 올라감·회복 뒤 새 이탈은 위 조건에 걸리지 않아 말한다.
    if (!stillOff && sameDirRepeat && stillness.isStillAt(now)) {
      if (_bundleLogText != message ||
          now.difference(_bundleLogAt!).inSeconds >= _cooldownSeconds) {
        _bundleLogAt = now;
        _bundleLogText = message;
        EventLog.instance.log('say.cancel', {'text': message, 'why': 'still'});
      }
      return null;
    }

    _lastAlertTime = now;
    _lastAlertClass = detectedClass;
    _lastAlertLevel = level;
    _bundleLogAt = now;
    _bundleLogText = message;
    _lastDecisionRapid = rapid;
    return message;
  }

  /// T130: 대기 슬롯의 진입 안내를 상태가 crossed·none·approach로 바뀌면 취소한다
  /// (`say.cancel` why=state). 취소했으면 true.
  ///
  /// 야간 실기기(`logs/log_20261024_191344.jsonl`): 이탈 경고 뒤에서 대기하던 진입
  /// 안내 6건이 건넌 순간·뒤에 재생됐다(지연 4.8~7.5초) — 대기 중인 진입 안내를
  /// 상태 변화로 거두는 장치가 없었다.
  @visibleForTesting
  bool cancelPendingEntryOnState(String detectedClass) {
    if (detectedClass != 'crossed' &&
        detectedClass != 'none' &&
        detectedClass != 'approach') {
      return false;
    }
    final entry = AppStrings.of(_language).enteredCrosswalkMessage;
    if (audioPolicy.pendingMessage != entry) return false;
    audioPolicy.clearPending();
    EventLog.instance.log('say.cancel', {'text': entry, 'why': 'state'});
    return true;
  }

  // T63: 구간이 바뀌었다는 1회성 사실 안내. "왼쪽/오른쪽으로 가세요"처럼
  // 반복되는 경고가 아니므로 decideMessage와 분리했고, 클래스가 실제로
  // 바뀐 프레임에서만 값을 낸다 — 매 프레임 재확인하는 것이 아니다.
  // 3초 재쿨다운은 판정이 approach<->front 사이에서 떨릴 때(flicker) 같은
  // 안내가 반복 발화되는 것을 막기 위함이다.
  @visibleForTesting
  String? decidePhaseMessage(
    String previousClass,
    String detectedClass,
    DateTime now,
  ) {
    final entering = previousClass == 'approach' &&
        (detectedClass == 'front' ||
            detectedClass == 'left' ||
            detectedClass == 'right');
    // T103(2026-09-27, 사용자 확정): 다 건넘은 **위 -> crossed** 순간에 안내한다.
    // 위 -> none은 **안내하지 않는다** — 줄무늬가 잠깐 안 보이거나(X형 교차
    // 횡단보도 가운데) 오판일 수 있어서다. 다 건넌 과정은 위 -> crossed -> none
    // 이고, crossed -> none/approach, none/approach -> crossed도 침묵이다.
    // T118(A2): hold가 "발밑이 인도"로 일찍 풀려 none/approach를 거쳤어도, 그 뒤
    // 창([groundReleaseCrossedUntil]) 안의 crossed는 다 건넌 것으로 본다 — 풀리지 않았다면 hold -> crossed
    // (= 위 -> crossed)였을 경우다. 한 번 쓰거나 다시 위로 들어오면 비운다.
    final releasedAt = _holdReleasedByGroundAt;
    final afterGroundRelease = releasedAt != null &&
        (previousClass == 'none' || previousClass == 'approach') &&
        detectedClass == 'crossed' &&
        !now.isAfter(
            groundReleaseCrossedUntil(releasedAt, _releasedHoldStartedAt));
    if (detectedClass == 'crossed' ||
        detectedClass == 'front' ||
        detectedClass == 'left' ||
        detectedClass == 'right') {
      _holdReleasedByGroundAt = null;
      _releasedHoldStartedAt = null;
    }
    final exiting = ((previousClass == 'front' ||
                previousClass == 'left' ||
                previousClass == 'right') &&
            detectedClass == 'crossed') ||
        afterGroundRelease;
    // T93(2026-09-15, 사용자 요청): approach로 **들어올 때** "앞에 횡단보도가
    // 있습니다"를 1회 안내한다. T51에서 approach를 침묵시켰던 것을 뒤집는다
    // (이탈 경고 decideMessage는 여전히 approach에서 침묵 — 방향 경고가 아니라
    // 구간 안내이므로 여기 둔다).
    // 판정표: none/콜드스타트 -> approach = 안내. front/left/right ->
    // approach는 **안내하지 않는다** — 건넌 직후 오검출(실기기 #10)일 가능성이
    // 커서, 잘못된 "앞에 횡단보도"를 말하느니 침묵한다. 5_crossed 스위치가
    // 생기면 재검토.
    final approaching = detectedClass == 'approach' &&
        (previousClass == 'none' || previousClass == '');
    if (!entering && !exiting && !approaching) return null;

    final strings = AppStrings.of(_language);
    final message = approaching
        ? strings.approachAheadMessage
        : entering
            ? strings.enteredCrosswalkMessage
            : strings.crossedCrosswalkMessage;
    // T123: 같은 문장만 3초 안에 다시 말하지 않는다(떨림 방지). 다른 진행 안내는
    // 서로 막지 않는다.
    final last = _lastPhaseAt[message];
    if (last != null && now.difference(last).inSeconds < _cooldownSeconds) {
      return null;
    }
    _lastPhaseAt[message] = now;
    return message;
  }

  // T63: 이탈(left/right)에서 정상(front)으로 돌아왔을 때만 1회 발화한다.
  // 처음부터 똑바로 가고 있을 때는 front가 항상 무음이므로(decideMessage가
  // front에는 반응하지 않음) 이 함수를 거치지 않으면 "직진하세요"가 나갈
  // 방법이 없다 — 회복 여부는 반드시 직전 클래스를 봐야 알 수 있다.
  @visibleForTesting
  ///
  /// T102: [atEdge](끝 + 이미 중앙 쪽으로 틀어 front)면 "직진하세요" 대신
  /// [decideEdgeTurnedMessage]가 "그대로 가세요"를 낸다 — 여기서는 침묵.
  String? decideRecoveryMessage(
    String previousClass,
    String detectedClass,
    DateTime now, {
    bool atEdge = false,
  }) {
    final recovered = (previousClass == 'left' || previousClass == 'right') &&
        detectedClass == 'front' &&
        !atEdge;
    if (!recovered) return null;

    if (_lastRecoveryAt != null &&
        now.difference(_lastRecoveryAt!).inSeconds < _cooldownSeconds) {
      return null;
    }
    _lastRecoveryAt = now;

    return AppStrings.of(_language).recoveredMessage;
  }

  // T102(사용자 확정 2026-09-27): 끝인데 이미 중앙 쪽으로 틀어 직진 판정
  // (T100 a안)이 나면 "그대로 가세요"를 1회 안내한다. front는 원래 무음이라
  // 안내가 없으면 사용자는 방향이 맞는지 알 수 없었다. 그 상태로 **들어올
  // 때만** 내고(머무는 동안 반복하지 않음), 경계에서 떨릴 때 반복되지 않게
  // 다른 1회성 안내와 같은 3초 재쿨다운을 둔다.
  @visibleForTesting
  String? decideEdgeTurnedMessage(
    String detectedClass,
    DateTime now, {
    required bool atEdge,
  }) {
    final edgeTurned = detectedClass == 'front' && atEdge;
    final entering = edgeTurned && !_lastEdgeTurned;
    _lastEdgeTurned = edgeTurned;
    if (!entering) return null;

    if (_lastEdgeTurnedAt != null &&
        now.difference(_lastEdgeTurnedAt!).inSeconds < _cooldownSeconds) {
      return null;
    }
    _lastEdgeTurnedAt = now;
    return AppStrings.of(_language).edgeTurnedMessage;
  }

  void _holdRecovery(String message, DateTime now, {required bool edge}) {
    _heldRecovery = message;
    _heldRecoveryAt = now;
    _heldRecoveryIsEdge = edge;
    EventLog.instance.log('say.defer', {'text': message});
  }

  void _clearHeldRecovery() {
    _heldRecovery = null;
    _heldRecoveryAt = null;
    _heldRecoveryIsEdge = false;
  }

  /// T108 Q1 판정표(사용자 확정 2026-10-12). [heldAt]은 회복 안내를 보류한 시각.
  ///
  /// | 이번 판정 | 보류 경과                         | 이탈 경고 재생 중 | 결과   |
  /// |---|---|---|---|
  /// | front 아님 | —                                 | —                 | cancel |
  /// | front      | > [recoveryHold] + [recoveryMaxWait] | —              | expire |
  /// | front      | < [recoveryHold]                  | —                 | wait   |
  /// | front      | >= [recoveryHold]                 | 예                | wait   |
  /// | front      | >= [recoveryHold]                 | 아니오            | speak  |
  @visibleForTesting
  HeldRecoveryVerdict decideHeldRecovery(
    String detectedClass,
    DateTime heldAt,
    DateTime now, {
    required bool deviationPlaying,
  }) {
    if (detectedClass != 'front') return HeldRecoveryVerdict.cancel;
    final held = now.difference(heldAt);
    if (held > recoveryHold + recoveryMaxWait) return HeldRecoveryVerdict.expire;
    if (held < recoveryHold || deviationPlaying) return HeldRecoveryVerdict.wait;
    return HeldRecoveryVerdict.speak;
  }

  /// T108 Q3: [message]가 재생 중인 [activeMessage](멈춤 블록)를 대체하는가.
  @visibleForTesting
  static bool supersedesDotBlock(
    String message,
    String? activeMessage, {
    required String approachMessage,
    required String dotBlockMessage,
  }) =>
      message == approachMessage && activeMessage == dotBlockMessage;

  // T39: runtime setters used by SettingsScreen. Each applies immediately
  // for the remainder of the session (no persistence — restarting the app
  // resets to the defaults above). SettingsScreen calls these without
  // awaiting (fire-and-forget, matching alert()'s unawaited(_speak(...))
  // pattern), so any platform-channel exception must be caught here rather
  // than left to become an unhandled async error in the root zone.
  Future<void> updateLanguage(AppLanguage language) async {
    _language = language;
    EventLog.instance.log('set', {'key': 'lang', 'value': language.name});
    try {
      await _tts.setLanguage(ttsLocaleCode(language));
    } catch (e) {
      debugPrint('FeedbackService.updateLanguage: TTS error: $e');
    }
  }

  Future<void> updateSpeechRate(double rate) async {
    _speechRate = rate;
    EventLog.instance.log('set', {'key': 'speechRate', 'value': rate});
    _appliedRate = rate;
    try {
      await _tts.setSpeechRate(rate);
    } catch (e) {
      debugPrint('FeedbackService.updateSpeechRate: TTS error: $e');
    }
  }

  void updateVibrationDuration(int milliseconds) {
    _vibrationDurationMs = milliseconds;
    EventLog.instance
        .log('set', {'key': 'vibrationMs', 'value': milliseconds});
  }

  // Bumps the speech generation and marks speech as active. Returns the
  // generation token this call owns, so its own finishSpeechGeneration()
  // call (after `await _tts.speak()` resolves) only resets `isSpeaking` if
  // no newer call has started in the meantime.
  @visibleForTesting
  int beginSpeechGeneration() {
    final generation = ++_speechGeneration;
    isSpeaking.value = true;
    return generation;
  }

  // Resets `isSpeaking` to false only if [generation] is still the most
  // recent one issued by beginSpeechGeneration(); a stale/late resolution
  // from an earlier _speak() call is a no-op.
  @visibleForTesting
  void finishSpeechGeneration(int generation) {
    if (generation == _speechGeneration) {
      isSpeaking.value = false;
    }
  }

  // T38 redesign: no callbacks. `await _tts.speak(message)` itself only
  // resolves once the native side actually finishes (or otherwise settles)
  // that specific speak() invocation, because awaitSpeakCompletion(true)
  // was enabled in init() (see comment there for the verified platform
  // behavior this relies on). `await _tts.stop()` first cancels/settles
  // any in-flight previous utterance's own speak() Future before this
  // call's speak() begins (unchanged ordering from before this redesign).
  // If another alert()/announceError() call starts and bumps the
  // generation while this await is still pending, finishSpeechGeneration
  // below is a no-op for the stale generation — reusing the
  // already-verified generation guard.
  // T38 fix: flutter_tts-4.2.5's Android `onError` callbacks (both
  // overloads) never resolve `speakResult` (only `stop()` or a normal
  // `onDone` do — FlutterTtsPlugin.kt's error handlers only forward
  // "speak.onError", they don't call `speakResult.success(...)`). Since
  // awaitSpeakCompletion(true) is enabled in init(), a TTS engine error
  // would otherwise leave `await _tts.speak(message)` pending forever.
  // A 10-second timeout (comfortably longer than these short ko/en
  // deviation prompts take to speak) bounds that wait so `isSpeaking`
  // cannot get stuck permanently; the exception is swallowed because a
  // timed-out speak is not something the caller can act on, but the
  // generation is still finished so state stays consistent.
  static const _speakTimeout = Duration(seconds: 10);

  // T61: 우선순위 판정을 앞에 붙였다. 판정표·TTL·무음 예산은 AudioPolicy가
  // 갖고 있고(docs/AudioPolicy.md), 여기서는 그 결정을 집행만 한다.
  // 기존 generation 가드와 stop-before-speak 순서는 손대지 않았다.
  Future<void> _speak(
    String message, {
    FeedbackPriority priority = FeedbackPriority.p3,
    P0Rank rank = P0Rank.deviation,
    bool supersedes = false,
    DateTime? requestedAt,
    double? rate,
    bool afterP0 = false,
    bool atP0Cut = false,
  }) async {
    final now = DateTime.now();
    // T131: 끼워 넣은 진입 안내 재생 중이면 이탈·회복 P0는 끊지 않고 기다린다.
    if (priority == FeedbackPriority.p0 &&
        audioPolicy.holdsP0ForInsert(rank, now)) {
      _holdP0ForInsert(message, rank, rate, now);
      return;
    }
    // T132 ①: 이 P0가 재생 중인 P0를 끊으려는데 진입 안내가 대기 중이면, 그 순간
    // 진입 안내를 먼저 말하고 이 P0는 기다리게 한다.
    if (priority == FeedbackPriority.p0 &&
        _insertEntryAtP0Cut(message, rank, rate, now)) {
      return;
    }
    // T108: 대기 슬롯에서 다시 꺼낸 요청은 처음 요청 시각을 그대로 쓴다(TTL 기준).
    final firstAt = requestedAt ?? now;
    var action = audioPolicy.decide(priority, now,
        rank: rank,
        message: message,
        supersedes: supersedes,
        afterP0: afterP0,
        atP0Cut: atP0Cut);
    var why = audioPolicy.lastReason;
    if (action == SpeechAction.queue) {
      // 만료된 대기 항목이 슬롯을 막지 않게 먼저 치운다(버린 것은 기록).
      final expiredPriority = audioPolicy.pendingPriority;
      final expiredWhy = audioPolicy.pendingExpiry(now);
      final expired = audioPolicy.takeExpiredPending(now);
      if (expired != null && expiredPriority != null) {
        EventLog.instance.log('say.ttl', {
          'text': expired,
          'p': expiredPriority.index,
          if (expiredWhy != null) 'why': expiredWhy,
        });
      }
    }
    if (action == SpeechAction.queue &&
        !audioPolicy.putPending(priority, message, firstAt,
            supersedes: supersedes,
            // T130: 진입 안내는 늦으면 틀린 말이라 상한을 3초로 줄인다.
            maxWait: message == AppStrings.of(_language).enteredCrosswalkMessage
                ? AudioPolicy.entryMaxPendingWait
                : null)) {
      // 슬롯 한 칸을 먼저 온 안내가 차지하고 있다.
      action = SpeechAction.drop;
      why = 'slot_full';
    }
    // T106: 정책 판단을 그대로 기록한다(재생·대기·버림과 그 이유).
    EventLog.instance.log('say', {
      'text': message,
      'p': priority.index,
      'act': action.name,
      'why': why,
      // T124: 빠른 상승 문장이면 요청한 속도.
      if (rate != null) 'rate': rate,
    });
    if (action == SpeechAction.drop) return;
    if (action == SpeechAction.queue) {
      // 재생 중인 것이 없으면(최소 간격 대기) 간격이 끝나는 시각에 꺼낸다.
      // 재생 중이면 그 발화가 끝날 때 finally에서 꺼낸다.
      if (audioPolicy.activePriority == null) _scheduleDrain();
      return;
    }

    final generation = beginSpeechGeneration();
    final start = DateTime.now();
    // T132 ②: 바로 재생된(why=ok) 진입 안내도 끼운 진입 안내와 같은 보호를 받는다
    // (10/25 저녁 기록: 바로 재생된 진입 2건이 0.97·1.26초 만에 interrupt_p1로 잘림).
    final inserted = priority == FeedbackPriority.p1 &&
        message == AppStrings.of(_language).enteredCrosswalkMessage;
    audioPolicy.markStarted(priority,
        rank: rank, message: message, insertedAt: inserted ? start : null);
    var result = 'done';
    // T124: 이 발화의 속도. 바꿨으면 그 값과 바꾸는 데 걸린 시간을 say.end에 남긴다
    // (실기기에서 변경·복귀 지연을 재기 위해).
    final wantRate = rate ?? _speechRate;
    int? rateMs;
    await _tts.stop();
    try {
      // T121 F1: stop을 기다리는 동안 더 새 발화가 시작됐으면 speak를 보내지 않는다.
      // 보내면 플랫폼 순서가 stop·stop·speak(이것)·speak(새것)이 되고, 플러그인은
      // 재생 중에 온 speak(새것)를 재생 없이 성공으로 돌려준다(flutter_tts-4.2.5
      // FlutterTtsPlugin.kt:304-309) — 정책이 끊으라고 한 새 발화가 삼켜졌다
      // (10/16 L627, 10/19 L3381: 이탈 경고 대신 "진입했습니다"가 들림).
      if (generation == _speechGeneration &&
          (_appliedRate ?? _speechRate) != wantRate) {
        final t = DateTime.now();
        _appliedRate = wantRate;
        try {
          await _tts.setSpeechRate(wantRate);
        } catch (e) {
          // 속도를 못 바꿔도 안전 안내는 말한다.
          debugPrint('FeedbackService._speak: setSpeechRate error: $e');
        }
        rateMs = DateTime.now().difference(t).inMilliseconds;
      }
      if (generation != _speechGeneration) {
        result = 'superseded';
      } else {
        await _tts.speak(message).timeout(_speakTimeout);
      }
    } on TimeoutException {
      result = 'timeout';
      debugPrint(
          'FeedbackService._speak: timed out waiting for TTS completion');
    } catch (e) {
      // alert() fires this via unawaited(), so nothing else observes this
      // Future — any TTS engine error (not just a timeout) must be caught
      // here or it becomes an unhandled async error in the root zone.
      result = 'error';
      debugPrint('FeedbackService._speak: TTS error: $e');
    } finally {
      final end = DateTime.now();
      // T108: 다른 발화에 끊겨 끝났으면 새 발화의 '재생 중' 상태를 지우지 않는다.
      final current = generation == _speechGeneration;
      // T132 ②: 더 새 발화가 시작돼(stop) 끝났으면 cut — 전에는 done이라 dur로만
      // 구분했다.
      if (result == 'done' && !current) result = 'cut';
      // T106: 끝난 시각·걸린 시간. 다른 안내가 끊었으면(stop) 짧게 끝난다.
      EventLog.instance.log('say.end', {
        'text': message,
        'p': priority.index,
        'res': result,
        'dur': end.difference(start).inMilliseconds,
        if (rateMs != null) 'rate': wantRate,
        if (rateMs != null) 'rateMs': rateMs,
      });
      finishSpeechGeneration(generation);
      audioPolicy.markFinished(priority, start, end, current: current);
      // T131: 끼워 넣은 진입 안내가 끝나면(끊겼어도) 기다리게 한 P0를 내보낸다.
      // T132 ②: 바로 재생된 진입 안내도 같다.
      if (inserted) _releaseInsertHeld();
      if (current) {
        // T131: P0가 끝났는데 진입 안내가 대기 중이면 최소 간격 없이 바로 끼워 넣는다.
        if (priority == FeedbackPriority.p0 &&
            audioPolicy.pendingMessage ==
                AppStrings.of(_language).enteredCrosswalkMessage) {
          _drainTimer?.cancel();
          _drainPending(afterP0: true);
        } else {
          _scheduleDrain();
        }
      }
    }
  }

  /// T132 ①(사용자 선택 A, 2026-10-25): 재생 중인 P0를 다른 P0가 끊는 순간에
  /// 진입 안내가 대기 중이고 처음 요청부터 3초(`entryMaxPendingWait`) 안이면, 진입
  /// 안내를 그 순간 말하고(`say` why=p0_cut, 앞 P0는 `say.end` res=cut) 끊으려던 P0는
  /// T131 규칙으로 기다리게 한다(`say.defer` why=insert). 차도(danger)와, P0 규칙상
  /// 끊지 않는 P0(busy_p0·same_p0)는 해당하지 않는다. 끼웠으면 true.
  ///
  /// 10/25 저녁 기록: 진입 안내 만료 6건 중 5건은 첫 P0가 1.5~2.35초에 다른 P0
  /// (강조 문장 4·반대 방향 1)에 끊겨, 다음 P0가 끝났을 때 이미 3초가 지났다.
  bool _insertEntryAtP0Cut(
      String message, P0Rank rank, double? rate, DateTime now) {
    if (rank == P0Rank.danger ||
        audioPolicy.activePriority != FeedbackPriority.p0) {
      return false;
    }
    final entry = AppStrings.of(_language).enteredCrosswalkMessage;
    final at = audioPolicy.pendingAt;
    if (audioPolicy.pendingMessage != entry || at == null) return false;
    if (audioPolicy.decide(FeedbackPriority.p0, now,
            rank: rank, message: message) !=
        SpeechAction.speakNow) {
      return false;
    }
    if (audioPolicy.pendingExpiry(now) != null) return false;
    audioPolicy.clearPending();
    // _speak는 첫 await 전까지 바로 실행된다 — 여기서 돌아오면 진입 안내가 이미
    // 재생 중(insertStartedAt 있음)이라 아래에서 이 P0를 기다리게 할 수 있다.
    unawaited(_speak(entry,
        priority: FeedbackPriority.p1, requestedAt: at, atP0Cut: true));
    if (audioPolicy.activeMessage != entry) {
      // 예산 등으로 진입 안내를 말하지 않았다 — 이 P0는 평소대로.
      return false;
    }
    _holdP0ForInsert(message, rank, rate, now);
    return true;
  }

  /// T131: 끼워 넣은 진입 안내 재생 중에 온 P0를 기다리게 한다. 슬롯은 1개 —
  /// 더 새 P0가 오면 그것으로 바꾼다(지금 상태에 맞는 쪽, 앞의 것은
  /// `say.cancel` why=superseded). 기다리기 시작하면 `say.defer` why=insert.
  void _holdP0ForInsert(
      String message, P0Rank rank, double? rate, DateTime now) {
    final old = _insertHeld;
    if (old != null) {
      EventLog.instance.log('say.cancel', {'text': old, 'why': 'superseded'});
    }
    _insertHeld = message;
    _insertHeldRank = rank;
    _insertHeldRate = rate;
    _insertHeldClass = _lastRawClass ?? '';
    EventLog.instance.log('say.defer', {'text': message, 'why': 'insert'});
    // 진입 안내가 [AudioPolicy.insertMaxHold] 안에 끝나지 않으면(느린 속도·TTS 멈춤)
    // 그때 내보낸다 — 이때는 정책이 기다리지 않으므로 진입 안내를 끊는다.
    final at = audioPolicy.insertStartedAt;
    if (_insertHoldTimer == null && at != null) {
      final left = at.add(AudioPolicy.insertMaxHold).difference(now);
      _insertHoldTimer = Timer(
          (left.isNegative ? Duration.zero : left) + drainMargin,
          _releaseInsertHeld);
    }
  }

  /// T131: 기다리게 한 P0를 내보낸다. 기다리는 사이 분류 상태가 바뀌었으면
  /// (예: left 경고를 기다리는데 front로 돌아옴) 늦은 경고라 말하지 않는다
  /// (`say.cancel` why=state).
  void _releaseInsertHeld() {
    _insertHoldTimer?.cancel();
    _insertHoldTimer = null;
    final held = _insertHeld;
    _insertHeld = null;
    if (held == null) return;
    if ((_lastRawClass ?? '') != _insertHeldClass) {
      EventLog.instance.log('say.cancel', {'text': held, 'why': 'state'});
      return;
    }
    unawaited(_speak(held,
        priority: FeedbackPriority.p0,
        rank: _insertHeldRank,
        rate: _insertHeldRate));
  }

  /// T108 Q2: 대기 슬롯을 최소 간격이 끝나는 시각에 꺼내도록 예약한다.
  ///
  /// T108 전에는 발화가 끝나자마자 꺼냈는데, 그 순간은 최소 간격(끝난 뒤 1.5초)
  /// 안이라 P1이 다시 버려졌다(10/02 기록 L3367 대기 -> L3378 min_gap 버림).
  void _scheduleDrain() {
    if (audioPolicy.pendingPriority == null) return;
    final now = DateTime.now();
    final allowed = audioPolicy.nextAllowedAt;
    final wait = drainDelay(allowed, now);
    _drainTimer?.cancel();
    _drainTimer = Timer(wait, _drainPending);
  }

  /// 대기 슬롯에 남은 항목을 꺼내 발화한다. TTL이 지났으면 버린다 —
  /// 늦게 도착한 안내는 정보가 아니라 오정보다. T126: TTL은 마지막 P0가 끝난
  /// 때부터 센다(`AudioPolicy.pendingExpiry`).
  ///
  /// T131: [afterP0]면 P0가 끝난 직후 끼워 넣는 진입 안내다(최소 간격을 보지 않음).
  void _drainPending({bool afterP0 = false}) {
    final pri = audioPolicy.pendingPriority;
    final msg = audioPolicy.pendingMessage;
    final at = audioPolicy.pendingAt;
    if (pri == null || msg == null || at == null) return;
    // 그사이 다른 발화가 시작됐으면 그 발화가 끝날 때 다시 꺼낸다.
    if (audioPolicy.activePriority != null) return;
    final expiredWhy = audioPolicy.pendingExpiry(DateTime.now());
    audioPolicy.clearPending();
    if (expiredWhy != null) {
      EventLog.instance.log(
          'say.ttl', {'text': msg, 'p': pri.index, 'why': expiredWhy});
      return;
    }
    unawaited(_speak(msg, priority: pri, requestedAt: at, afterP0: afterP0));
  }

  /// T106: 진동 기록 한 줄의 내용. [kind]는 left·right·recover·road·line_on.
  /// 앱이 진동을 **요청한** 기록이다 — 모터가 실제로 떨렸는지는 알 수 없다.
  /// T132 ④: 방향 진동이면 [level](`lvl`, 이탈 단계)과 [gapMs](`gap`, 적용한
  /// 같은 방향 반복 간격)를 붙인다.
  @visibleForTesting
  static Map<String, Object?> vibrationLogData(
    String kind,
    List<int> pattern, {
    required bool hasVibrator,
    required bool supportsPattern,
    required int fallbackMs,
    int? level,
    int? gapMs,
  }) {
    final extra = {
      if (level != null) 'lvl': level,
      if (gapMs != null) 'gap': gapMs,
    };
    if (!hasVibrator) {
      return {'kind': kind, 'ok': false, 'why': 'no_vibrator', ...extra};
    }
    return {
      'kind': kind,
      'ok': true,
      'mode': supportsPattern ? 'pattern' : 'single',
      'pat': supportsPattern ? pattern : <int>[0, fallbackMs],
      ...extra,
    };
  }

  // Marks vibration as active and (re)schedules the timer that will clear
  // it. Cancelling any previous timer first guarantees that only the most
  // recently started vibration decides when `isVibrating` goes back to
  // false, even if alert() is called again before the previous vibration's
  // 500ms window elapsed (e.g. a left->right class change bypasses the
  // cooldown).
  @visibleForTesting
  void activateVibrationIndicator([int? durationMs]) {
    isVibrating.value = true;
    _vibrationTimer?.cancel();
    _vibrationTimer = Timer(
      Duration(milliseconds: durationMs ?? _vibrationDurationMs),
      () => isVibrating.value = false,
    );
  }

  // T38 fix: vibration (the app's core safety feedback) must never be
  // blocked by TTS. Previously `await _speak(message)` ran before the
  // vibration branch, so a hung/slow `_tts.speak()` call (e.g. an
  // unresolved onError, see _speak()'s doc comment) would delay or
  // silently suppress vibration too. `unawaited` (dart:async) starts
  // speech without the vibration branch waiting on its completion; the
  // two feedback channels now run independently.
  Future<void> alert(String detectedClass, double confidence,
      {double? angleDegrees, bool atEdge = false}) async {
    final now = DateTime.now();

    // T63: 발화 여부와 무관하게 진짜 직전 클래스를 먼저 뽑아 둔다 —
    // 아래에서 _lastRawClass를 덮어쓰기 전에 읽어야 전이를 감지할 수 있다.
    final previous = _lastRawClass ?? '';
    _lastRawClass = detectedClass;

    // T130: 대기 중인 진입 안내는 횡단보도 위를 벗어나면 취소한다.
    cancelPendingEntryOnState(detectedClass);

    // 음성 — 이탈 경고는 P0다. 무음 예산·최소 간격에서 면제되며, 재생 중인
    // 하위 등급 안내를 끊는다. T84: 강도는 각도로 판정한다(confidence는
    // 더 이상 강도에 쓰지 않는다 — 호출부 호환을 위해 인자는 남겨 둔다).
    // T121 F2: 구간 안내보다 **먼저** 요청한다. 같은 프레임에 "진입했습니다"(P1)가
    // 함께 나면 P1은 이탈 경고 재생 중이라 기존 대기 규칙(wait_p0, TTL 3초)을 따른다.
    // 전에는 P1을 먼저 요청해 P0가 그것을 끊어야 했고, 그 경쟁에서 P0가 삼켜졌다.
    final message =
        decideMessage(detectedClass, angleDegrees, now, atEdge: atEdge);
    if (message != null) {
      unawaited(_speak(message,
          priority: FeedbackPriority.p0,
          rate: _lastDecisionRapid ? rapidRate(_speechRate) : null));
    }

    // 구간 전이 안내(P1) — "횡단보도에 진입했습니다" / "횡단보도를 건넜습니다".
    // 반복 경고가 아니라 1회성 사실이므로 이탈 경고보다 낮은 우선순위다.
    final phaseMessage = decidePhaseMessage(previous, detectedClass, now);
    if (phaseMessage != null) {
      // T108 Q3: "앞에 횡단보도"는 재생 중이거나 대기 중인
      // "멈춤 블록입니다"를 대체한다(같은 연석에서 같은 뜻 — 멈춰서 확인).
      final dotBlock = AppStrings.of(_language).surfaceDotBlockMessage;
      final supersedes = supersedesDotBlock(
          phaseMessage, audioPolicy.activeMessage,
          approachMessage: AppStrings.of(_language).approachAheadMessage,
          dotBlockMessage: dotBlock);
      // T118: 보류 중인 멈춤 블록은 말하지 않고 앞에 횡단보도만 말한다.
      if (phaseMessage == AppStrings.of(_language).approachAheadMessage &&
          _heldDotBlockAt != null) {
        _dotBlockTimer?.cancel();
        _heldDotBlockAt = null;
        EventLog.instance
            .log('say.cancel', {'text': dotBlock, 'why': 'superseded'});
      }
      if (phaseMessage == AppStrings.of(_language).approachAheadMessage &&
          audioPolicy.pendingMessage == dotBlock) {
        audioPolicy.clearPending();
        EventLog.instance
            .log('say.cancel', {'text': dotBlock, 'why': 'superseded'});
      }
      unawaited(_speak(phaseMessage,
          priority: FeedbackPriority.p1, supersedes: supersedes));
    }

    // 이탈에서 회복했을 때의 확인 안내(P0 회복 순위). 처음부터 똑바로 가는
    // 경우는 절대 나가지 않는다. T108 Q1: 바로 말하지 않고 보류한다.
    final recoveryMessage =
        decideRecoveryMessage(previous, detectedClass, now, atEdge: atEdge);
    if (recoveryMessage != null) _holdRecovery(recoveryMessage, now, edge: false);

    // T102: 끝에서 이미 중앙 쪽으로 틀었을 때의 확인 안내(회복 안내와 같은
    // 채널). 위 회복 안내는 atEdge면 침묵하므로 둘이 함께 나가지 않는다.
    final edgeTurnedMessage =
        decideEdgeTurnedMessage(detectedClass, now, atEdge: atEdge);
    if (edgeTurnedMessage != null) {
      _holdRecovery(edgeTurnedMessage, now, edge: true);
    }

    // T108 Q1: 보류한 회복 안내를 front가 유지됐으면 말하고, 흔들렸으면 취소한다.
    final deviationPlaying = audioPolicy.activePriority == FeedbackPriority.p0 &&
        (audioPolicy.activeRank ?? P0Rank.deviation).index <
            P0Rank.recovery.index;
    final held = _heldRecovery;
    final heldAt = _heldRecoveryAt;
    if (held != null && heldAt != null) {
      final verdict =
          decideHeldRecovery(detectedClass, heldAt, now, deviationPlaying: deviationPlaying);
      switch (verdict) {
        case HeldRecoveryVerdict.wait:
          break;
        case HeldRecoveryVerdict.speak:
          _clearHeldRecovery();
          unawaited(_speak(held,
              priority: FeedbackPriority.p0, rank: P0Rank.recovery));
        case HeldRecoveryVerdict.cancel:
          // 흔들림 — 말하지 않았으므로 쿨다운도 되돌려, 곧 진짜로 회복하면 안내한다.
          if (_heldRecoveryIsEdge) {
            _lastEdgeTurnedAt = null;
          } else {
            _lastRecoveryAt = null;
          }
          _clearHeldRecovery();
          EventLog.instance.log('say.cancel', {'text': held, 'why': 'flicker'});
        case HeldRecoveryVerdict.expire:
          _clearHeldRecovery();
          EventLog.instance.log('say.ttl', {'text': held, 'p': 0});
      }
    }

    // 진동 — T61: 좌/우 패턴을 분리했다. 이전에는 두 방향이 같은 진동이라
    // 방향 정보가 음성에만 존재했고, 도로 소음에 음성이 묻히면 방향이 통째로
    // 사라졌다. `front`로 복귀할 때는 짧은 확인 진동 1회가 나간다.
    // T136(사용자 승인): 좌우를 다시 같은 패턴(짧게 1번)으로 — 방향은 음성으로만.
    // 음성이 쿨다운에 걸린 프레임에서도 진동 판단은 별도로 수행한다.
    // T132 ④: 같은 방향 반복 간격은 이번 프레임의 이탈 단계로 정한다.
    final pattern = vibrationPolicy.decidePattern(
        detectedClass, now, _vibrationDurationMs,
        level: _frameDeviationLevel ?? 0);

    // T106: 경고 입력과 이번에 낸 것(음성 문장 여부·진동 여부). 말이 안 나간
    // 이유(쿨다운)도 이 줄과 'say' 줄을 함께 보면 알 수 있다.
    EventLog.instance.log('alert', {
      'cls': detectedClass,
      'conf': confidence,
      'ang': angleDegrees,
      'edge': atEdge,
      'msg': message,
      'phase': phaseMessage,
      'recover': recoveryMessage,
      'edgeTurned': edgeTurnedMessage,
      'vib': pattern != null,
    });
    if (pattern == null) return;

    final kind = detectedClass == 'front' ? 'recover' : detectedClass;
    // T132 ④: 방향 진동이면 단계와 적용한 반복 간격(ms)을 함께 남긴다.
    final directional = kind == 'left' || kind == 'right';
    final level = directional ? vibrationPolicy.lastLevel : null;
    final gapMs =
        directional ? vibrationPolicy.lastInterval.inMilliseconds : null;
    // T136: 방향 진동은 단일 진동으로 내려가도 짧게(가장 짧은 간격 400ms보다 짧게).
    final fallbackMs =
        directional ? VibrationPolicy.directionPulseMs : _vibrationDurationMs;
    if (await Vibration.hasVibrator() ?? false) {
      // 패턴 진동을 지원하지 않는 기기에서는 단일 진동으로 내려간다.
      // 방향은 음성으로만 전달되지만, 아무 알림도 없는 것보다는 낫다.
      final supportsPattern = await Vibration.hasCustomVibrationsSupport();
      if (supportsPattern) {
        Vibration.vibrate(pattern: pattern);
      } else {
        Vibration.vibrate(duration: fallbackMs);
      }
      EventLog.instance.log(
          'vib',
          vibrationLogData(kind, pattern,
              hasVibrator: true,
              supportsPattern: supportsPattern,
              fallbackMs: fallbackMs,
              level: level,
              gapMs: gapMs));
      final total = pattern.fold<int>(0, (a, b) => a + b);
      activateVibrationIndicator(total > 0 ? total : fallbackMs);
    } else {
      EventLog.instance.log(
          'vib',
          vibrationLogData(kind, pattern,
              hasVibrator: false,
              supportsPattern: false,
              fallbackMs: fallbackMs,
              level: level,
              gapMs: gapMs));
    }
  }

  /// T104: 노면 안내(`SurfaceGuide` 이벤트)를 말하고 진동한다.
  /// 등급·진동은 `docs/AudioPolicy.md` 노면 안내 표(사용자 확정 2026-09-30):
  ///   차도 P0 + 짧게 3번 / 멈춤 블록 P1 / 선형 방향·벗어남 P2 / 블록 위 = 진동만(짧게 1번).
  Future<void> surfaceAlert(List<SurfaceEvent> events) async {
    if (events.isEmpty) return;
    final strings = AppStrings.of(_language);
    final shortMs = (_vibrationDurationMs ~/ 4).clamp(80, _vibrationDurationMs);
    List<int>? pattern;
    for (final e in events) {
      switch (e) {
        case SurfaceEvent.road:
          unawaited(_speak(strings.surfaceRoadMessage,
              priority: FeedbackPriority.p0, rank: P0Rank.danger));
          pattern = surfaceRoadPattern(shortMs);
        case SurfaceEvent.dotBlock:
          if (holdsDotBlock(_lastRawClass ?? '')) {
            _holdDotBlock(strings.surfaceDotBlockMessage, DateTime.now());
          } else {
            unawaited(_speak(strings.surfaceDotBlockMessage,
                priority: FeedbackPriority.p1));
          }
        case SurfaceEvent.linearRight:
          unawaited(_speak(strings.surfaceLinearRightMessage,
              priority: FeedbackPriority.p2));
        case SurfaceEvent.linearLeft:
          unawaited(_speak(strings.surfaceLinearLeftMessage,
              priority: FeedbackPriority.p2));
        case SurfaceEvent.linearLost:
          unawaited(_speak(strings.surfaceLinearLostMessage,
              priority: FeedbackPriority.p2));
        case SurfaceEvent.linearOn:
          pattern ??= <int>[0, shortMs];
      }
    }
    if (pattern == null) return;
    final kind = events.contains(SurfaceEvent.road) ? 'road' : 'line_on';
    if (await Vibration.hasVibrator()) {
      final supportsPattern = await Vibration.hasCustomVibrationsSupport();
      if (supportsPattern) {
        Vibration.vibrate(pattern: pattern);
      } else {
        Vibration.vibrate(duration: _vibrationDurationMs);
      }
      EventLog.instance.log(
          'vib',
          vibrationLogData(kind, pattern,
              hasVibrator: true,
              supportsPattern: supportsPattern,
              fallbackMs: _vibrationDurationMs));
      final total = pattern.fold<int>(0, (a, b) => a + b);
      activateVibrationIndicator(total > 0 ? total : _vibrationDurationMs);
    } else {
      EventLog.instance.log(
          'vib',
          vibrationLogData(kind, pattern,
              hasVibrator: false,
              supportsPattern: false,
              fallbackMs: _vibrationDurationMs));
    }
  }

  /// T105: 주의 구역 안내(`CautionGuide` 이벤트)를 말한다. 등급·진동은
  /// `docs/AudioPolicy.md` 주의 구역 표(사용자 확정 2026-10-01): 둘 다 P2, 진동 없음.
  /// P2라 무음 예산·최소 간격을 따르고, 걸리면 버린다(대기하지 않음).
  Future<void> cautionAlert(List<CautionEvent> events) async {
    final message = cautionMessage(events, AppStrings.of(_language));
    if (message == null) return;
    unawaited(_speak(message, priority: FeedbackPriority.p2));
  }

  /// T105 C8(사용자 확정 2026-10-12): 같은 판정에서 둘 다 나면 **둘 다 차례로** —
  /// 한 문장으로 이어 말한다(따로 요청하면 P2 동급이라 뒤 것이 앞 것을 끊는다).
  /// 순서는 판정표 번호 순(C1 맨홀·그레이팅 -> C2 가로수 구역).
  @visibleForTesting
  static String? cautionMessage(List<CautionEvent> events, AppStrings strings) {
    final parts = [
      if (events.contains(CautionEvent.manholeGrating)) strings.cautionManholeMessage,
      if (events.contains(CautionEvent.treeZone)) strings.cautionTreeMessage,
    ];
    return parts.isEmpty ? null : parts.join('. ');
  }

  /// T104: 차도 진동 — 짧게 3번(‧‧‧). 기존 좌(‧‧)·우(—)·복귀(짧게 1번)와 겹치지 않는다.
  /// T136: 좌우가 같은 짧게 1번(150ms)이 된 뒤에도 차도는 그대로(바꾸지 않음).
  @visibleForTesting
  static List<int> surfaceRoadPattern(int shortMs) =>
      <int>[0, shortMs, shortMs, shortMs, shortMs, shortMs];

  // 앱 초기화 실패 시 사용자에게 오류 상황을 음성으로 안내
  Future<void> announceError(String message) async {
    await _speak(message, priority: FeedbackPriority.p3);
  }

  // T40: general-purpose TTS read-aloud, used by OnboardingScreen to speak
  // the posture guidance + legal disclaimer on entry. Reuses the same
  // _speak() plumbing as alert()/announceError() (stop-before-speak,
  // generation guard, 10s timeout), so it participates in the same
  // isSpeaking state and race protections without duplicating that logic.
  Future<void> speak(String message) async {
    await _speak(message, priority: FeedbackPriority.p3);
  }

  Future<void> dispose() async {
    await _tts.stop();
    _vibrationTimer?.cancel();
    _drainTimer?.cancel();
    _dotBlockTimer?.cancel();
    _insertHoldTimer?.cancel();
    isSpeaking.value = false;
    isVibrating.value = false;
    isSpeaking.dispose();
    isVibrating.dispose();
  }
}
