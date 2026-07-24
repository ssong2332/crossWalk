// Widget tests for OnboardingScreen (T40): posture guidance + legal
// disclaimer content, TTS read-aloud on entry, and confirm-button
// navigation to CameraScreen.
//
// Same platform-channel mocking pattern as camera_screen_test.dart /
// settings_screen_test.dart (channel names verified against actual package
// source in those files' comments).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/messages.g.dart';
import 'package:crosswalk_app/screens/onboarding_screen.dart';
import 'package:crosswalk_app/screens/camera_screen.dart';
import 'package:crosswalk_app/services/feedback_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ttsChannel = MethodChannel('flutter_tts');
  const permissionChannel =
      MethodChannel('flutter.baseflow.com/permissions/methods');
  final wakelockToggleChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
    WakelockPlusApi.pigeonChannelCodec,
  );

  const cameraPermissionValue = 1;
  const deniedStatusValue = 0;

  late List<String> spokenMessages;

  void mockFlutterTts() {
    spokenMessages = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, (call) async {
      if (call.method == 'speak') {
        spokenMessages.add(call.arguments as String);
      }
      return 1;
    });
  }

  void mockPermissionHandler(int statusValueToReturn) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, (call) async {
      switch (call.method) {
        case 'requestPermissions':
          return <int, int>{cameraPermissionValue: statusValueToReturn};
        case 'openAppSettings':
          return true;
        default:
          return null;
      }
    });
  }

  void mockWakelockPlus() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(wakelockToggleChannel.name, (message) async {
      return wakelockToggleChannel.codec.encodeMessage(<Object?>[null]);
    });
  }

  setUp(() {
    mockFlutterTts();
    mockPermissionHandler(deniedStatusValue);
    mockWakelockPlus();
    TestWidgetsFlutterBinding.instance.platformDispatcher.localeTestValue =
        const Locale('ko', 'KR');
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(wakelockToggleChannel.name, null);
    TestWidgetsFlutterBinding.instance.platformDispatcher.clearLocaleTestValue();
  });

  group('OnboardingScreen — content', () {
    testWidgets('shows the posture guidance, disclaimer (verbatim), and '
        'confirm button', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: OnboardingScreen()));
      await tester.pumpAndSettle();

      expect(find.text('시작하기 전에'), findsOneWidget);
      expect(find.text('안전 이용 안내'), findsOneWidget);
      expect(find.text('가슴거치 착용 방법'), findsOneWidget);
      expect(
        find.text('스마트폰을 목걸이형 거치대에 걸어 가슴 정면에 가깝게, 살짝 아래를 향하도록 착용하세요.'),
        findsOneWidget,
      );
      expect(find.text('법적 고지'), findsOneWidget);
      expect(find.text('법률 검토 전 초안'), findsOneWidget);
      // Verbatim user-approved disclaimer copy (docs/Tasks.md T40
      // acceptance criterion (2)).
      expect(
        find.text(
          '이 앱은 횡단보도 이탈을 감지해 음성·진동으로 알려주는 보조 도구입니다. '
          '흰지팡이·안내견·동행인의 판단을 대신하지 않으며, '
          '최종 판단과 주의는 항상 보행자 본인에게 있습니다.',
        ),
        findsOneWidget,
      );
      expect(find.text('확인했습니다'), findsOneWidget);
    });
  });

  group('OnboardingScreen — TTS on entry', () {
    testWidgets('reads the posture guidance + disclaimer aloud on entry',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: OnboardingScreen()));
      await tester.pumpAndSettle();

      expect(spokenMessages, hasLength(1));
      expect(spokenMessages.single, contains('목걸이형 거치대'));
      expect(spokenMessages.single, contains('흰지팡이·안내견·동행인'));
    });
  });

  group('OnboardingScreen — confirm navigation', () {
    testWidgets('tapping 확인했습니다 navigates to CameraScreen with the '
        'detected language', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: OnboardingScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('확인했습니다'));
      await tester.pumpAndSettle();

      expect(find.byType(OnboardingScreen), findsNothing);
      expect(find.byType(CameraScreen), findsOneWidget);
      // CameraScreen received the Korean language from OnboardingScreen
      // rather than re-detecting it, so its Korean error label shows.
      expect(find.text('카메라 권한 필요'), findsOneWidget);
    });
  });

  group('OnboardingScreen — shared FeedbackService instance', () {
    testWidgets(
        'passes the exact injected FeedbackService instance through to '
        'CameraScreen (regression: reviewer flagged this sharing path as '
        'untested)', (tester) async {
      final sharedInstance = FeedbackService();
      addTearDown(sharedInstance.dispose);

      await tester.pumpWidget(
        MaterialApp(home: OnboardingScreen(feedback: sharedInstance)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('확인했습니다'));
      await tester.pumpAndSettle();

      expect(find.byType(OnboardingScreen), findsNothing);
      final cameraScreenFinder = find.byType(CameraScreen);
      expect(cameraScreenFinder, findsOneWidget);

      final cameraScreen = tester.widget<CameraScreen>(cameraScreenFinder);
      expect(identical(cameraScreen.feedback, sharedInstance), isTrue);

      // Indirect check that the shared instance was NOT disposed by
      // OnboardingScreen when it navigated away and unmounted (only an
      // instance OnboardingScreen created itself is disposed — see
      // _ownsFeedback in onboarding_screen.dart). A disposed
      // ValueNotifier throws on any further .value access, so reading it
      // here would fail if the sharing/ownership logic regressed.
      expect(() => sharedInstance.isSpeaking.value, returnsNormally);
      expect(() => sharedInstance.isVibrating.value, returnsNormally);
    });
  });
}
