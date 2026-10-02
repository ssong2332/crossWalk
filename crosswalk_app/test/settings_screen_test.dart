// Widget tests for SettingsScreen (T39): language selection, TTS-rate /
// vibration-strength sliders, and the disabled "screen reader
// optimization" placeholder.
//
// FeedbackService.updateLanguage()/updateSpeechRate() await
// _tts.setLanguage()/setSpeechRate() on the real `flutter_tts` platform
// channel, so it must be mocked (same pattern as
// camera_screen_test.dart's mockFlutterTts() / feedback_service_test.dart).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/localization/app_strings.dart';
import 'package:crosswalk_app/screens/settings_screen.dart';
import 'package:crosswalk_app/services/feedback_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter_tts 4.2.5 (lib/flutter_tts.dart:330):
  // static const MethodChannel _channel = MethodChannel('flutter_tts');
  const ttsChannel = MethodChannel('flutter_tts');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, (call) async => 1);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, null);
  });

  Widget buildSettingsScreen({
    required FeedbackService feedback,
    required AppLanguage language,
    required ValueChanged<AppLanguage> onLanguageChanged,
    bool torchEnabled = false,
    Future<void> Function(bool enabled)? onTorchChanged,
    bool powerSaveMode = true,
    ValueChanged<bool>? onPowerSaveModeChanged,
    bool surfaceGuidanceEnabled = false,
    ValueChanged<bool>? onSurfaceGuidanceChanged,
    bool eventLogEnabled = true,
    ValueChanged<bool>? onEventLogChanged,
    Future<String?> Function()? onShareEventLog,
  }) {
    return MaterialApp(
      home: SettingsScreen(
        feedback: feedback,
        language: language,
        onLanguageChanged: onLanguageChanged,
        torchEnabled: torchEnabled,
        onTorchChanged: onTorchChanged ?? (_) async {},
        powerSaveMode: powerSaveMode,
        onPowerSaveModeChanged: onPowerSaveModeChanged ?? (_) {},
        surfaceGuidanceEnabled: surfaceGuidanceEnabled,
        onSurfaceGuidanceChanged: onSurfaceGuidanceChanged,
        eventLogEnabled: eventLogEnabled,
        onEventLogChanged: onEventLogChanged,
        onShareEventLog: onShareEventLog,
      ),
    );
  }

  group('SettingsScreen — initial values', () {
    testWidgets('shows the FeedbackService defaults (0.5 rate, 500ms)',
        (tester) async {
      final feedback = FeedbackService();

      await tester.pumpWidget(buildSettingsScreen(
        feedback: feedback,
        language: AppLanguage.ko,
        onLanguageChanged: (_) {},
      ));
      await tester.pumpAndSettle();

      expect(find.text('설정'), findsOneWidget);
      // Claude Design import: label and value are now separate Text
      // widgets in a Row (label left, value right) rather than one combined
      // "Label: value" string.
      expect(find.text('TTS 속도'), findsOneWidget);
      expect(find.text('0.5'), findsOneWidget);
      expect(find.text('진동 세기'), findsOneWidget);
      expect(find.text('500ms'), findsOneWidget);
      // T63: 세 개의 SwitchListTile이 있다 — 배터리 절약 모드(T63, 켜짐
      // 기본값), 화면 읽기 프로그램 최적화(비활성, T39), 손전등(T37, 꺼짐
      // 기본값). onChanged 유무만으로는 배터리 절약과 손전등이 둘 다
      // 활성이라 구분이 안 되므로 제목 텍스트로 특정한다.
      //
      // ListView는 SliverList라 뷰포트+캐시 범위 밖의 자식은 Element
      // 트리에 아예 안 들어간다(find로 못 찾는다) — 배터리 절약 섹션이
      // 추가되며 손전등 타일이 그 범위 밖으로 밀려났다. 손전등을 찾기
      // 전에 스크롤해서 실제로 빌드되게 만들어야 한다.
      final powerSaveTile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, '배터리 절약 모드'),
      );
      expect(powerSaveTile.value, isTrue);

      await tester.scrollUntilVisible(
        find.text('손전등 켜기'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      final torchTile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, '손전등 켜기'),
      );
      expect(torchTile.value, isFalse);

      final screenReaderTile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, '화면 읽기 프로그램 최적화'),
      );
      expect(screenReaderTile.value, isFalse);
      expect(screenReaderTile.onChanged, isNull);
    });
  });

  group('SettingsScreen — 배터리 절약 모드 토글 (T63)', () {
    testWidgets(
      '기본값이 켜짐이고, 끄면 onPowerSaveModeChanged(false)를 호출한다',
      (tester) async {
        final feedback = FeedbackService();
        bool? toggledTo;

        await tester.pumpWidget(buildSettingsScreen(
          feedback: feedback,
          language: AppLanguage.ko,
          onLanguageChanged: (_) {},
          powerSaveMode: true,
          onPowerSaveModeChanged: (enabled) => toggledTo = enabled,
        ));
        await tester.pumpAndSettle();

        final tile = tester.widget<SwitchListTile>(
          find.widgetWithText(SwitchListTile, '배터리 절약 모드'),
        );
        expect(tile.value, isTrue);

        await tester.tap(find.byWidget(tile));
        await tester.pumpAndSettle();

        expect(toggledTo, isFalse);
      },
    );
  });

  group('SettingsScreen — 노면 안내 토글 (T104)', () {
    testWidgets('콜백이 없으면 스위치를 그리지 않는다', (tester) async {
      await tester.pumpWidget(buildSettingsScreen(
        feedback: FeedbackService(),
        language: AppLanguage.ko,
        onLanguageChanged: (_) {},
      ));
      await tester.pumpAndSettle();
      expect(find.text('노면 안내 (실험)'), findsNothing);
    });

    testWidgets('기본 꺼짐이고, 켜면 onSurfaceGuidanceChanged(true)를 호출한다',
        (tester) async {
      bool? toggledTo;
      await tester.pumpWidget(buildSettingsScreen(
        feedback: FeedbackService(),
        language: AppLanguage.ko,
        onLanguageChanged: (_) {},
        onSurfaceGuidanceChanged: (v) => toggledTo = v,
      ));
      await tester.pumpAndSettle();
      final finder = find.widgetWithText(SwitchListTile, '노면 안내 (실험)');
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(finder).value, isFalse);
      await tester.tap(finder);
      await tester.pumpAndSettle();
      expect(toggledTo, isTrue);
    });
  });

  group('SettingsScreen — 개발용 기록 (T106)', () {
    testWidgets('콜백이 없으면 구역을 그리지 않는다', (tester) async {
      // 목록 전체가 한 화면에 빌드되게 크게 잡는다 — 그래야 "없음"이 의미가 있다
      // (ListView는 화면 밖 자식을 아예 만들지 않는다).
      tester.view.physicalSize = const Size(800, 5000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(buildSettingsScreen(
        feedback: FeedbackService(),
        language: AppLanguage.ko,
        onLanguageChanged: (_) {},
      ));
      await tester.pumpAndSettle();
      expect(find.text('빌드 dev'), findsOneWidget, reason: '목록 끝까지 빌드됨');
      expect(find.text('기록 남기기'), findsNothing);
      expect(find.text('기록 보내기'), findsNothing);
    });

    testWidgets('기본 켬이고, 끄면 onEventLogChanged(false)를 호출한다',
        (tester) async {
      bool? toggledTo;
      await tester.pumpWidget(buildSettingsScreen(
        feedback: FeedbackService(),
        language: AppLanguage.ko,
        onLanguageChanged: (_) {},
        onEventLogChanged: (v) => toggledTo = v,
      ));
      await tester.pumpAndSettle();
      final finder = find.widgetWithText(SwitchListTile, '기록 남기기');
      await tester.scrollUntilVisible(
        finder,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(finder).value, isTrue);
      await tester.tap(finder);
      await tester.pumpAndSettle();
      expect(toggledTo, isFalse);
    });

    testWidgets('기록 보내기를 누르면 onShareEventLog를 부르고, 돌려준 문구를 띄운다',
        (tester) async {
      var calls = 0;
      await tester.pumpWidget(buildSettingsScreen(
        feedback: FeedbackService(),
        language: AppLanguage.ko,
        onLanguageChanged: (_) {},
        onEventLogChanged: (_) {},
        onShareEventLog: () async {
          calls++;
          return '보낼 기록이 없습니다';
        },
      ));
      await tester.pumpAndSettle();
      final button = find.text('기록 보내기');
      await tester.scrollUntilVisible(
        button,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('보낼 기록이 없습니다'), findsOneWidget);
    });
  });

  group('SettingsScreen — low-light torch toggle (T37)', () {
    testWidgets(
      'is off by default and invokes onTorchChanged(true) when tapped',
      (tester) async {
        final feedback = FeedbackService();
        bool? toggledTo;

        await tester.pumpWidget(buildSettingsScreen(
          feedback: feedback,
          language: AppLanguage.ko,
          onLanguageChanged: (_) {},
          torchEnabled: false,
          onTorchChanged: (enabled) async => toggledTo = enabled,
        ));
        await tester.pumpAndSettle();

        // T63: 배터리 절약 섹션이 위에 추가되며 손전등 타일이 SliverList의
        // 빌드 범위 밖으로 밀려났다 — 찾기 전에 스크롤해야 한다.
        await tester.scrollUntilVisible(
          find.text('손전등 켜기'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();

        final torchTile = tester.widget<SwitchListTile>(
          find.widgetWithText(SwitchListTile, '손전등 켜기'),
        );
        expect(torchTile.value, isFalse);

        // Claude Design import: the new slow/fast + weak/strong sub-labels
        // under each slider push the torch tile below the default test
        // viewport (800x600) — scroll it into view before tapping, since
        // SettingsScreen's body is a ListView and the tile is genuinely
        // reachable by a real user scrolling, just not on-screen at the
        // initial scroll offset.
        await tester.ensureVisible(find.byWidget(torchTile));
        await tester.pumpAndSettle();

        await tester.tap(find.byWidget(torchTile));
        await tester.pumpAndSettle();

        expect(toggledTo, isTrue);
      },
    );

    testWidgets('reflects an initial torchEnabled=true from the parent',
        (tester) async {
      final feedback = FeedbackService();

      await tester.pumpWidget(buildSettingsScreen(
        feedback: feedback,
        language: AppLanguage.ko,
        onLanguageChanged: (_) {},
        torchEnabled: true,
      ));
      await tester.pumpAndSettle();

      // T63: 배터리 절약(onChanged != null)과 손전등(onChanged != null)이
      // 둘 다 활성 스위치라 onChanged 유무로는 더 이상 구분이 안 된다 —
      // 제목 텍스트로 특정한다. 손전등은 스크롤해야 빌드된다(위 설명 참조).
      await tester.scrollUntilVisible(
        find.text('손전등 켜기'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      final torchTile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, '손전등 켜기'),
      );
      expect(torchTile.value, isTrue);
    });
  });

  group('SettingsScreen — language selection', () {
    testWidgets(
      'tapping English updates FeedbackService.language and invokes '
      'onLanguageChanged',
      (tester) async {
        final feedback = FeedbackService();
        AppLanguage? changedTo;

        await tester.pumpWidget(buildSettingsScreen(
          feedback: feedback,
          language: AppLanguage.ko,
          onLanguageChanged: (lang) => changedTo = lang,
        ));
        await tester.pumpAndSettle();

        await tester.tap(find.text('영어'));
        await tester.pumpAndSettle();

        expect(feedback.language, AppLanguage.en);
        expect(changedTo, AppLanguage.en);
        // The screen's own labels must reflect the new language too.
        expect(find.text('Settings'), findsOneWidget);
      },
    );
  });

  group('SettingsScreen — build identifier (T45)', () {
    testWidgets(
        'shows the default "dev" identifier when BUILD_SHA is not '
        'injected', (tester) async {
      final feedback = FeedbackService();

      await tester.pumpWidget(buildSettingsScreen(
        feedback: feedback,
        language: AppLanguage.ko,
        onLanguageChanged: (_) {},
      ));
      await tester.pumpAndSettle();

      // `flutter test` passes no --dart-define, so kBuildSha falls back to
      // 'dev' and is shown unchanged (shorter than the 7-char short SHA).
      expect(buildShaShort, 'dev');

      final label = find.text('빌드 dev');
      // The identifier sits at the very bottom of the ListView, below the
      // default 800x600 test viewport — same situation as the torch tile.
      await tester.scrollUntilVisible(
        label,
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(label, findsOneWidget);
    });
  });

  group('SettingsScreen — sliders', () {
    testWidgets(
        'dragging the TTS-rate slider updates FeedbackService.speechRate',
        (tester) async {
      final feedback = FeedbackService();

      await tester.pumpWidget(buildSettingsScreen(
        feedback: feedback,
        language: AppLanguage.ko,
        onLanguageChanged: (_) {},
      ));
      await tester.pumpAndSettle();

      final sliders = find.byType(Slider);
      expect(sliders, findsNWidgets(2));

      // First slider = TTS rate (0.1..1.0). Drag toward the max end.
      await tester.drag(sliders.first, const Offset(200, 0));
      await tester.pumpAndSettle();

      expect(feedback.speechRate, isNot(0.5));
      expect(feedback.speechRate, greaterThan(0.5));
    });

    testWidgets(
      'dragging the vibration-strength slider updates '
      'FeedbackService.vibrationDurationMs',
      (tester) async {
        final feedback = FeedbackService();

        await tester.pumpWidget(buildSettingsScreen(
          feedback: feedback,
          language: AppLanguage.ko,
          onLanguageChanged: (_) {},
        ));
        await tester.pumpAndSettle();

        final sliders = find.byType(Slider);

        // Second slider = vibration duration (200..1000ms).
        await tester.drag(sliders.last, const Offset(200, 0));
        await tester.pumpAndSettle();

        expect(feedback.vibrationDurationMs, isNot(500));
        expect(feedback.vibrationDurationMs, greaterThan(500));
      },
    );
  });
}
