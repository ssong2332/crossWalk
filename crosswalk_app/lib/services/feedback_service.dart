import 'package:flutter_tts/flutter_tts.dart';
import 'package:meta/meta.dart';
import 'package:vibration/vibration.dart';
import '../localization/app_strings.dart';

class FeedbackService {
  final FlutterTts _tts = FlutterTts();
  DateTime? _lastAlertTime;
  String? _lastAlertClass;

  // Defaults to Korean so behavior is unchanged for callers/tests that
  // never call init() (matches this app's pre-localization fallback).
  AppLanguage _language = AppLanguage.ko;

  static const _cooldownSeconds = 3;

  Future<void> init({AppLanguage language = AppLanguage.ko}) async {
    _language = language;
    await _tts.setLanguage(ttsLocaleCode(_language));
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
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

  Future<void> alert(String detectedClass) async {
    final message = decideMessage(detectedClass, DateTime.now());
    if (message == null) return;

    await _tts.stop();
    await _tts.speak(message);

    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(duration: 500);
    }
  }

  // 앱 초기화 실패 시 사용자에게 오류 상황을 음성으로 안내
  Future<void> announceError(String message) async {
    await _tts.stop();
    await _tts.speak(message);
  }

  Future<void> dispose() async {
    await _tts.stop();
  }
}
