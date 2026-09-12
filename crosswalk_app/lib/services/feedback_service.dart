import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:vibration/vibration.dart';
import '../localization/app_strings.dart';
import 'audio_policy.dart';
import 'severity_latch.dart';

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

  /// 화면 표시용 — 지금 보고 중인 이탈 강도.
  bool get isSevere => severityLatch.isSevere;

  /// T84: '크게 벗어남' 판정 각도(도). 이 값 이상 틀어지면 심함.
  /// 근거(누수 없는 CV, left/right 354장, 정답=|기하각도|>=30):
  ///   20도 재현율 89%/정밀도 90%, **25도 82%/92%**, 30도 72%/94%.
  /// 25는 사용자가 고른 균형점(2026-09-13). 실기기 결과에 따라 여기만 바꾼다.
  static const double severeAngleDegrees = 25.0;

  DateTime? _lastAlertTime;
  String? _lastAlertClass;
  bool? _lastAlertSevere;

  // T63: 매 alert() 호출마다(메시지가 실제로 나갔는지와 무관하게) 갱신되는
  // "직전 판정 클래스". 구간 전이(진입/이탈 완료/복귀)를 감지하려면 발화
  // 여부와 무관하게 진짜 이전 프레임의 클래스를 알아야 한다 — _lastAlertClass는
  // 쿨다운에 걸려 갱신이 안 될 수 있어 이 목적에 쓸 수 없다.
  String? _lastRawClass;

  /// T82: [severityLatch]를 언제 초기화할지 판단하기 위한 직전 이탈 방향.
  /// `_lastRawClass`는 `alert()`가 `decideMessage()`를 부르기 전에 이미
  /// 현재 클래스로 덮어써서 이 목적에 쓸 수 없다.
  String? _lastSeverityClass;

  DateTime? _lastPhaseAt;
  DateTime? _lastRecoveryAt;

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
  String? decideMessage(
      String detectedClass, double? angleDegrees, DateTime now) {
    if (detectedClass != 'left' && detectedClass != 'right') {
      severityLatch.reset();
      _lastSeverityClass = null;
      return null;
    }
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
    if (_lastAlertTime != null &&
        _lastAlertClass == detectedClass &&
        _lastAlertSevere == severe &&
        now.difference(_lastAlertTime!).inSeconds < _cooldownSeconds) {
      return null;
    }

    _lastAlertTime = now;
    _lastAlertClass = detectedClass;
    _lastAlertSevere = severe;

    final strings = AppStrings.of(_language);
    if (detectedClass == 'left') {
      return severe
          ? strings.leftDeviationMessageSevere
          : strings.leftDeviationMessageMild;
    }
    return severe
        ? strings.rightDeviationMessageSevere
        : strings.rightDeviationMessageMild;
  }

  // T63: 구간이 바뀌었다는 1회성 사실 안내. "왼쪽/오른쪽으로 이동하세요"처럼
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
    final exiting = (previousClass == 'front' ||
            previousClass == 'left' ||
            previousClass == 'right') &&
        detectedClass == 'none';
    if (!entering && !exiting) return null;

    if (_lastPhaseAt != null &&
        now.difference(_lastPhaseAt!).inSeconds < _cooldownSeconds) {
      return null;
    }
    _lastPhaseAt = now;

    final strings = AppStrings.of(_language);
    return entering
        ? strings.enteredCrosswalkMessage
        : strings.crossedCrosswalkMessage;
  }

  // T63: 이탈(left/right)에서 정상(front)으로 돌아왔을 때만 1회 발화한다.
  // 처음부터 똑바로 가고 있을 때는 front가 항상 무음이므로(decideMessage가
  // front에는 반응하지 않음) 이 함수를 거치지 않으면 "직진하세요"가 나갈
  // 방법이 없다 — 회복 여부는 반드시 직전 클래스를 봐야 알 수 있다.
  @visibleForTesting
  String? decideRecoveryMessage(
    String previousClass,
    String detectedClass,
    DateTime now,
  ) {
    final recovered = (previousClass == 'left' || previousClass == 'right') &&
        detectedClass == 'front';
    if (!recovered) return null;

    if (_lastRecoveryAt != null &&
        now.difference(_lastRecoveryAt!).inSeconds < _cooldownSeconds) {
      return null;
    }
    _lastRecoveryAt = now;

    return AppStrings.of(_language).recoveredMessage;
  }

  // T39: runtime setters used by SettingsScreen. Each applies immediately
  // for the remainder of the session (no persistence — restarting the app
  // resets to the defaults above). SettingsScreen calls these without
  // awaiting (fire-and-forget, matching alert()'s unawaited(_speak(...))
  // pattern), so any platform-channel exception must be caught here rather
  // than left to become an unhandled async error in the root zone.
  Future<void> updateLanguage(AppLanguage language) async {
    _language = language;
    try {
      await _tts.setLanguage(ttsLocaleCode(language));
    } catch (e) {
      debugPrint('FeedbackService.updateLanguage: TTS error: $e');
    }
  }

  Future<void> updateSpeechRate(double rate) async {
    _speechRate = rate;
    try {
      await _tts.setSpeechRate(rate);
    } catch (e) {
      debugPrint('FeedbackService.updateSpeechRate: TTS error: $e');
    }
  }

  void updateVibrationDuration(int milliseconds) {
    _vibrationDurationMs = milliseconds;
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
  }) async {
    final requestedAt = DateTime.now();
    final action = audioPolicy.decide(priority, requestedAt);
    if (action == SpeechAction.drop) return;
    if (action == SpeechAction.queue) {
      // 대기는 P1이 P0를 기다리는 한 칸뿐이다. 슬롯은 1개이며 TTL이 지나면 버린다.
      audioPolicy.putPending(priority, message, requestedAt);
      return;
    }

    final generation = beginSpeechGeneration();
    audioPolicy.markStarted(priority);
    final start = DateTime.now();
    await _tts.stop();
    try {
      await _tts.speak(message).timeout(_speakTimeout);
    } on TimeoutException {
      debugPrint(
          'FeedbackService._speak: timed out waiting for TTS completion');
    } catch (e) {
      // alert() fires this via unawaited(), so nothing else observes this
      // Future — any TTS engine error (not just a timeout) must be caught
      // here or it becomes an unhandled async error in the root zone.
      debugPrint('FeedbackService._speak: TTS error: $e');
    } finally {
      finishSpeechGeneration(generation);
      audioPolicy.markFinished(priority, start, DateTime.now());
      _drainPending();
    }
  }

  /// 대기 슬롯에 남은 항목을 꺼내 발화한다. TTL이 지났으면 버린다 —
  /// 늦게 도착한 안내는 정보가 아니라 오정보다.
  void _drainPending() {
    final pri = audioPolicy.pendingPriority;
    final msg = audioPolicy.pendingMessage;
    final at = audioPolicy.pendingAt;
    if (pri == null || msg == null || at == null) return;
    audioPolicy.clearPending();
    if (audioPolicy.isExpired(pri, at, DateTime.now())) return;
    unawaited(_speak(msg, priority: pri));
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
      {double? angleDegrees}) async {
    final now = DateTime.now();

    // T63: 발화 여부와 무관하게 진짜 직전 클래스를 먼저 뽑아 둔다 —
    // 아래에서 _lastRawClass를 덮어쓰기 전에 읽어야 전이를 감지할 수 있다.
    final previous = _lastRawClass ?? '';
    _lastRawClass = detectedClass;

    // 구간 전이 안내(P1) — "횡단보도에 진입했습니다" / "횡단보도를 건넜습니다".
    // 반복 경고가 아니라 1회성 사실이므로 이탈 경고보다 낮은 우선순위다.
    final phaseMessage = decidePhaseMessage(previous, detectedClass, now);
    if (phaseMessage != null) {
      unawaited(_speak(phaseMessage, priority: FeedbackPriority.p1));
    }

    // 이탈에서 회복했을 때의 확인 안내(P0) — 이탈 경고와 같은 채널이므로
    // 같은 우선순위를 준다. 처음부터 똑바로 가는 경우는 절대 나가지 않는다.
    final recoveryMessage = decideRecoveryMessage(previous, detectedClass, now);
    if (recoveryMessage != null) {
      unawaited(_speak(recoveryMessage, priority: FeedbackPriority.p0));
    }

    // 음성 — 이탈 경고는 P0다. 무음 예산·최소 간격에서 면제되며, 재생 중인
    // 하위 등급 안내를 끊는다. T84: 강도는 각도로 판정한다(confidence는
    // 더 이상 강도에 쓰지 않는다 — 호출부 호환을 위해 인자는 남겨 둔다).
    final message = decideMessage(detectedClass, angleDegrees, now);
    if (message != null) {
      unawaited(_speak(message, priority: FeedbackPriority.p0));
    }

    // 진동 — T61: 좌/우 패턴을 분리했다. 이전에는 두 방향이 같은 진동이라
    // 방향 정보가 음성에만 존재했고, 도로 소음에 음성이 묻히면 방향이 통째로
    // 사라졌다. `front`로 복귀할 때는 짧은 확인 진동 1회가 나간다.
    // 음성이 쿨다운에 걸린 프레임에서도 진동 판단은 별도로 수행한다.
    final pattern =
        vibrationPolicy.decidePattern(detectedClass, now, _vibrationDurationMs);
    if (pattern == null) return;

    if (await Vibration.hasVibrator() ?? false) {
      // 패턴 진동을 지원하지 않는 기기에서는 단일 진동으로 내려간다.
      // 방향은 음성으로만 전달되지만, 아무 알림도 없는 것보다는 낫다.
      final supportsPattern = await Vibration.hasCustomVibrationsSupport();
      if (supportsPattern) {
        Vibration.vibrate(pattern: pattern);
      } else {
        Vibration.vibrate(duration: _vibrationDurationMs);
      }
      final total = pattern.fold<int>(0, (a, b) => a + b);
      activateVibrationIndicator(total > 0 ? total : _vibrationDurationMs);
    }
  }

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
    isSpeaking.value = false;
    isVibrating.value = false;
    isSpeaking.dispose();
    isVibrating.dispose();
  }
}
