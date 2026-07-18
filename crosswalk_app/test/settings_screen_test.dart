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
  }) {
    return MaterialApp(
      home: SettingsScreen(
        feedback: feedback,
        language: language,
        onLanguageChanged: onLanguageChanged,
        torchEnabled: torchEnabled,
        onTorchChanged: onTorchChanged ?? (_) async {},
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
      expect(find.textContaining('TTS 속도: 0.5'), findsOneWidget);
      expect(find.textContaining('진동 세기: 500ms'), findsOneWidget);
      // Two SwitchListTiles now exist: the disabled screen-reader
      // placeholder (T39) and the T37 torch toggle (enabled, off by
      // default) — disambiguate by `onChanged`.
      final switchTiles = tester.widgetList<SwitchListTile>(
        find.byType(SwitchListTile),
      );
      expect(switchTiles.length, 2);
      final screenReaderTile =
          switchTiles.firstWhere((t) => t.onChanged == null);
      expect(screenReaderTile.value, isFalse);
      expect(screenReaderTile.onChanged, isNull);

      final torchTile = switchTiles.firstWhere((t) => t.onChanged != null);
      expect(torchTile.value, isFalse);
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

        expect(find.text('손전등 켜기'), findsOneWidget);

        final switchTiles = tester.widgetList<SwitchListTile>(
          find.byType(SwitchListTile),
        );
        final torchTile = switchTiles.firstWhere((t) => t.onChanged != null);
        expect(torchTile.value, isFalse);

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

  group('SettingsScreen — sliders', () {
    testWidgets('dragging the TTS-rate slider updates FeedbackService.speechRate',
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
