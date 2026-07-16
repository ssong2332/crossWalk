import 'package:flutter_tts/flutter_tts.dart';
import 'package:meta/meta.dart';
import 'package:vibration/vibration.dart';

class FeedbackService {
  final FlutterTts _tts = FlutterTts();
  DateTime? _lastAlertTime;
  String? _lastAlertClass;

  static const _cooldownSeconds = 3;

  Future<void> init() async {
    await _tts.setLanguage('ko-KR');
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

    return detectedClass == 'left'
        ? '왼쪽으로 이탈했습니다. 오른쪽으로 이동하세요'
        : '오른쪽으로 이탈했습니다. 왼쪽으로 이동하세요';
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
