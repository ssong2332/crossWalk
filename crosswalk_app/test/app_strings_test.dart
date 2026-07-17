// Unit tests for T34's locale-to-language resolution and the externalized
// string tables (AppStrings). Pure logic, no platform channels involved.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/localization/app_strings.dart';

void main() {
  group('resolveAppLanguage', () {
    test('returns AppLanguage.en for an English locale', () {
      expect(resolveAppLanguage(const Locale('en')), AppLanguage.en);
      expect(resolveAppLanguage(const Locale('en', 'US')), AppLanguage.en);
    });

    test('is case-insensitive on the language code', () {
      expect(resolveAppLanguage(const Locale.fromSubtags(languageCode: 'EN')),
          AppLanguage.en);
    });

    test('falls back to AppLanguage.ko for a Korean locale', () {
      expect(resolveAppLanguage(const Locale('ko', 'KR')), AppLanguage.ko);
    });

    test('falls back to AppLanguage.ko for null (detection failure)', () {
      expect(resolveAppLanguage(null), AppLanguage.ko);
    });

    test('falls back to AppLanguage.ko for an unsupported language', () {
      // Only ko/en are supported (docs/Tasks.md T4); anything else must
      // fall back to Korean, not silently pick English.
      expect(resolveAppLanguage(const Locale('ja', 'JP')), AppLanguage.ko);
      expect(resolveAppLanguage(const Locale('fr')), AppLanguage.ko);
    });
  });

  group('ttsLocaleCode', () {
    test('maps AppLanguage.ko to ko-KR', () {
      expect(ttsLocaleCode(AppLanguage.ko), 'ko-KR');
    });

    test('maps AppLanguage.en to en-US', () {
      expect(ttsLocaleCode(AppLanguage.en), 'en-US');
    });
  });

  group('AppStrings.of', () {
    test('returns Korean strings for AppLanguage.ko', () {
      final strings = AppStrings.of(AppLanguage.ko);
      expect(strings.labelFront, '정상 진행');
      expect(strings.leftDeviationMessage, '왼쪽으로 이탈했습니다. 오른쪽으로 이동하세요');
      expect(strings.rightDeviationMessage, '오른쪽으로 이탈했습니다. 왼쪽으로 이동하세요');
    });

    test('returns English strings for AppLanguage.en', () {
      final strings = AppStrings.of(AppLanguage.en);
      expect(strings.labelFront, 'On track');
      expect(strings.leftDeviationMessage, 'You have drifted left. Move to the right');
      expect(strings.rightDeviationMessage, 'You have drifted right. Move to the left');
    });
  });
}
