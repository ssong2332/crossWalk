import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:vibration/vibration.dart';
import '../localization/app_strings.dart';

class FeedbackService {
  final FlutterTts _tts = FlutterTts();
  DateTime? _lastAlertTime;
  String? _lastAlertClass;

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
    await _tts.setSpeechRate(0.5);
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

  // 쿨다운/클래스 변경/전방(front) 무음 처리 결정 로직만 분리한 순수 함수.
  // 실제 시각을 인자로 받아 결정론적으로 테스트 가능하도록 함.
  @visibleForTesting
  String? decideMessage(String detectedClass, DateTime now) {
    if (detectedClass == 'front') return null;

    if (_lastAlertTime != null &&
        _lastAlertClass == detectedClass &&
        now.difference(_lastAlertTime!).inSeconds < _cooldownSeconds) {
      return null;
    }

    _lastAlertTime = now;
    _lastAlertClass = detectedClass;

    final strings = AppStrings.of(_language);
    return detectedClass == 'left'
        ? strings.leftDeviationMessage
        : strings.rightDeviationMessage;
  }

  static const _vibrationDurationMs = 500;

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

  Future<void> _speak(String message) async {
    final generation = beginSpeechGeneration();
    await _tts.stop();
    try {
      await _tts.speak(message).timeout(_speakTimeout);
    } on TimeoutException {
      debugPrint('FeedbackService._speak: timed out waiting for TTS completion');
    } catch (e) {
      // alert() fires this via unawaited(), so nothing else observes this
      // Future — any TTS engine error (not just a timeout) must be caught
      // here or it becomes an unhandled async error in the root zone.
      debugPrint('FeedbackService._speak: TTS error: $e');
    } finally {
      finishSpeechGeneration(generation);
    }
  }

  // Marks vibration as active and (re)schedules the timer that will clear
  // it. Cancelling any previous timer first guarantees that only the most
  // recently started vibration decides when `isVibrating` goes back to
  // false, even if alert() is called again before the previous vibration's
  // 500ms window elapsed (e.g. a left->right class change bypasses the
  // cooldown).
  @visibleForTesting
  void activateVibrationIndicator() {
    isVibrating.value = true;
    _vibrationTimer?.cancel();
    _vibrationTimer = Timer(
      const Duration(milliseconds: _vibrationDurationMs),
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
  Future<void> alert(String detectedClass) async {
    final message = decideMessage(detectedClass, DateTime.now());
    if (message == null) return;

    unawaited(_speak(message));

    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(duration: _vibrationDurationMs);
      activateVibrationIndicator();
    }
  }

  // 앱 초기화 실패 시 사용자에게 오류 상황을 음성으로 안내
  Future<void> announceError(String message) async {
    await _speak(message);
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
