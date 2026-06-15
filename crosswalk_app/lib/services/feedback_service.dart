import 'package:flutter_tts/flutter_tts.dart';
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

  Future<void> alert(String detectedClass) async {
    if (detectedClass == 'front') return;

    final now = DateTime.now();
    if (_lastAlertTime != null &&
        _lastAlertClass == detectedClass &&
        now.difference(_lastAlertTime!).inSeconds < _cooldownSeconds) {
      return;
    }

    _lastAlertTime = now;
    _lastAlertClass = detectedClass;

    final message = detectedClass == 'left'
        ? '왼쪽으로 이탈했습니다. 오른쪽으로 이동하세요'
        : '오른쪽으로 이탈했습니다. 왼쪽으로 이동하세요';

    await _tts.speak(message);

    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(duration: 500);
    }
  }

  Future<void> dispose() async {
    await _tts.stop();
  }
}
