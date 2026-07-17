import 'package:flutter/widgets.dart';

/// The exactly-two supported languages for this app (decided by the user,
/// see docs/Tasks.md T4/T34). No other language is in scope.
enum AppLanguage { ko, en }

/// Resolves a detected system [Locale] to one of the two supported
/// [AppLanguage]s. Falls back to Korean when [locale] is null, has an
/// unsupported/unrecognized language code, or detection otherwise fails —
/// preserving this app's pre-localization behavior (Korean-only) as the
/// default so existing users see no change unless their device is set to
/// English.
///
/// Public (not test-only) because production code (`CameraScreen`) calls
/// this directly to pick the active language at startup; it is also
/// exercised by dedicated unit tests.
AppLanguage resolveAppLanguage(Locale? locale) {
  if (locale != null && locale.languageCode.toLowerCase() == 'en') {
    return AppLanguage.en;
  }
  return AppLanguage.ko;
}

/// BCP-47 locale code to pass to `flutter_tts`'s `setLanguage()` for a given
/// [AppLanguage]. `flutter_tts` forwards this directly to the platform's
/// native TTS engine (Android `TextToSpeech`/iOS `AVSpeechSynthesizer`),
/// both of which support `en-US` as a standard built-in voice, so no
/// additional platform configuration is required.
String ttsLocaleCode(AppLanguage language) {
  switch (language) {
    case AppLanguage.en:
      return 'en-US';
    case AppLanguage.ko:
      return 'ko-KR';
  }
}

/// All user-facing strings and TTS phrases, externalized per [AppLanguage].
///
/// This app is a single-screen `StatefulWidget`/`setState` app with no
/// state-management library and no onboarding/settings screens (see
/// CLAUDE.md Stack, docs/Tasks.md T34 scope note); a lightweight strings
/// class matches that scale better than the full
/// `flutter_localizations`/ARB-file pipeline, which would add dependencies
/// and generated-code infrastructure disproportionate to two fixed,
/// hand-written languages.
class AppStrings {
  final String initializing;
  final String loadingModel;
  final String connectingCamera;
  final String detecting;

  final String labelFront;
  final String labelLeft;
  final String labelRight;

  final String cameraPermissionRequiredLabel;
  final String cameraPermissionRequiredSettingsLabel;
  final String cameraPermissionRequiredAnnouncement;
  final String cameraPermissionPermanentlyDeniedAnnouncement;
  final String cameraNotFoundLabel;
  final String cameraNotFoundAnnouncement;
  final String modelCorruptedLabel;
  final String modelCorruptedAnnouncement;
  final String detectionErrorLabel;
  final String detectionErrorAnnouncement;

  final String retryButton;
  final String openSettingsButton;
  final String confidenceLabel;

  final String leftDeviationMessage;
  final String rightDeviationMessage;

  const AppStrings._({
    required this.initializing,
    required this.loadingModel,
    required this.connectingCamera,
    required this.detecting,
    required this.labelFront,
    required this.labelLeft,
    required this.labelRight,
    required this.cameraPermissionRequiredLabel,
    required this.cameraPermissionRequiredSettingsLabel,
    required this.cameraPermissionRequiredAnnouncement,
    required this.cameraPermissionPermanentlyDeniedAnnouncement,
    required this.cameraNotFoundLabel,
    required this.cameraNotFoundAnnouncement,
    required this.modelCorruptedLabel,
    required this.modelCorruptedAnnouncement,
    required this.detectionErrorLabel,
    required this.detectionErrorAnnouncement,
    required this.retryButton,
    required this.openSettingsButton,
    required this.confidenceLabel,
    required this.leftDeviationMessage,
    required this.rightDeviationMessage,
  });

  static const AppStrings _ko = AppStrings._(
    initializing: '초기화 중...',
    loadingModel: '모델 로딩 중...',
    connectingCamera: '카메라 연결 중...',
    detecting: '감지 중...',
    labelFront: '정상 진행',
    labelLeft: '왼쪽 이탈',
    labelRight: '오른쪽 이탈',
    cameraPermissionRequiredLabel: '카메라 권한 필요',
    cameraPermissionRequiredSettingsLabel: '카메라 권한 필요 (설정 이동)',
    cameraPermissionRequiredAnnouncement: '카메라 권한이 필요합니다. 설정에서 허용해주세요.',
    cameraPermissionPermanentlyDeniedAnnouncement:
        '카메라 권한이 영구적으로 거부되었습니다. 설정 화면에서 권한을 허용해주세요.',
    cameraNotFoundLabel: '카메라 없음',
    cameraNotFoundAnnouncement: '카메라를 찾을 수 없습니다.',
    modelCorruptedLabel: '오류: 모델 손상',
    modelCorruptedAnnouncement: '모델 파일이 손상되었습니다. 앱을 다시 설치해주세요.',
    detectionErrorLabel: '오류: 감지 불가',
    detectionErrorAnnouncement: '앱 오류로 감지를 시작할 수 없습니다. 앱을 다시 시작해주세요.',
    retryButton: '다시 시도',
    openSettingsButton: '설정 열기',
    confidenceLabel: '신뢰도',
    leftDeviationMessage: '왼쪽으로 이탈했습니다. 오른쪽으로 이동하세요',
    rightDeviationMessage: '오른쪽으로 이탈했습니다. 왼쪽으로 이동하세요',
  );

  static const AppStrings _en = AppStrings._(
    initializing: 'Initializing...',
    loadingModel: 'Loading model...',
    connectingCamera: 'Connecting camera...',
    detecting: 'Detecting...',
    labelFront: 'On track',
    labelLeft: 'Drifted left',
    labelRight: 'Drifted right',
    cameraPermissionRequiredLabel: 'Camera permission required',
    cameraPermissionRequiredSettingsLabel:
        'Camera permission required (open settings)',
    cameraPermissionRequiredAnnouncement:
        'Camera permission is required. Please allow it in settings.',
    cameraPermissionPermanentlyDeniedAnnouncement:
        'Camera permission was permanently denied. Please allow it from the settings screen.',
    cameraNotFoundLabel: 'No camera found',
    cameraNotFoundAnnouncement: 'No camera could be found.',
    modelCorruptedLabel: 'Error: model corrupted',
    modelCorruptedAnnouncement:
        'The model file is corrupted. Please reinstall the app.',
    detectionErrorLabel: 'Error: detection unavailable',
    detectionErrorAnnouncement:
        'Detection could not start due to an app error. Please restart the app.',
    retryButton: 'Retry',
    openSettingsButton: 'Open settings',
    confidenceLabel: 'Confidence',
    leftDeviationMessage: 'You have drifted left. Move to the right',
    rightDeviationMessage: 'You have drifted right. Move to the left',
  );

  factory AppStrings.of(AppLanguage language) =>
      language == AppLanguage.en ? _en : _ko;
}
