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

    // T40: the disclaimer copy must match the user-approved original
    // verbatim (docs/Tasks.md T40 acceptance criterion (2)) — regression
    // guard against accidental edits to app_strings.dart.
    test('Korean onboarding disclaimer matches the user-approved copy '
        'verbatim', () {
      final strings = AppStrings.of(AppLanguage.ko);
      expect(
        strings.onboardingDisclaimerBody,
        '이 앱은 횡단보도 이탈을 감지해 음성·진동으로 알려주는 보조 도구입니다. '
        '흰지팡이·안내견·동행인의 판단을 대신하지 않으며, '
        '최종 판단과 주의는 항상 보행자 본인에게 있습니다.',
      );
    });

    test('English onboarding disclaimer is a non-empty translation', () {
      final strings = AppStrings.of(AppLanguage.en);
      expect(strings.onboardingDisclaimerBody, isNotEmpty);
      expect(strings.onboardingDisclaimerBody, contains('white cane'));
    });
  });
}
