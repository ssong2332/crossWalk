import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/onboarding_screen.dart';
import 'screens/settings_screen.dart' show kBuildSha;
import 'services/event_log.dart';
import 'services/feedback_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  // T106: 개발용 기록을 연다(기본 켬, docs/EventLog.md). 파일이 열리기 전의
  // 기록은 메모리에 모았다가 함께 쓰므로 기다리지 않는다.
  unawaited(EventLog.instance.start(info: {'build': kBuildSha}));
  runApp(const CrosswalkApp());
}

class CrosswalkApp extends StatefulWidget {
  const CrosswalkApp({super.key});

  @override
  State<CrosswalkApp> createState() => _CrosswalkAppState();
}

class _CrosswalkAppState extends State<CrosswalkApp> {
  // Reviewer fix (T40 follow-up): a single FeedbackService is created here
  // and shared by OnboardingScreen and CameraScreen. flutter_tts wraps one
  // static MethodChannel plus one native `speakResult` slot per app
  // (flutter_tts 4.2.5 lib/flutter_tts.dart:330; FlutterTtsPlugin.kt:38), so
  // two independently-constructed FlutterTts() instances would silently
  // share that native state anyway, each overwriting the other's method-call
  // handler. Owning one instance here makes the sharing explicit and keeps
  // T38's generation-token guard (_speechGeneration) protecting a single,
  // genuinely app-wide sequence instead of racing across instances.
  final FeedbackService _feedback = FeedbackService();

  @override
  void dispose() {
    _feedback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '횡단보도 이탈 감지',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      // T40: OnboardingScreen (posture guidance + legal disclaimer) now
      // runs first; it routes to CameraScreen once the user confirms. Both
      // screens are given the same FeedbackService instance owned here.
      home: OnboardingScreen(feedback: _feedback),
    );
  }
}
