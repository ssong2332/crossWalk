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
      // T62: 세 개의 SwitchListTile이 있다 — 배터리 절약 모드(T62, 켜짐
      // 기본값), 화면 읽기 프로그램 최적화(비활성, T39), 손전등(T37, 꺼짐
      // 기본값). onChanged 유무만으로는 배터리 절약과 손전등이 둘 다
      // 활성이라 구분이 안 되므로 제목 텍스트로 특정한다.
      final switchTiles = tester.widgetList<SwitchListTile>(
        find.byType(SwitchListTile),
      );
      expect(switchTiles.length, 3);

      final screenReaderTile =
          switchTiles.firstWhere((t) => t.onChanged == null);
      expect(screenReaderTile.value, isFalse);
      expect(screenReaderTile.onChanged, isNull);

      final powerSaveTile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, '배터리 절약 모드'),
      );
      expect(powerSaveTile.value, isTrue);

      final torchTile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, '손전등 켜기'),
      );
      expect(torchTile.value, isFalse);
    });
  });

  group('SettingsScreen — 배터리 절약 모드 토글 (T62)', () {
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

        expect(find.text('손전등 켜기'), findsOneWidget);

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

      final switchTiles = tester.widgetList<SwitchListTile>(
        find.byType(SwitchListTile),
      );
      final torchTile = switchTiles.firstWhere((t) => t.onChanged != null);
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
