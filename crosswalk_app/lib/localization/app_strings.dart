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

  // T38: accessibility labels for the voice/vibration status pills and the
  // settings-entry gear button added to CameraScreen's top-right corner.
  // Reviewer fix: these are neutral ("voice guidance" / "vibration
  // feedback"), not state-specific text, because the actual on/off state is
  // read from statusActiveValue/statusInactiveValue via Semantics' `value`
  // — a screen reader announces "<label>, <value>", e.g. "음성 안내, 켜짐".
  // Previously the label itself said "음성 재생 중" ("voice playing") even
  // while idle, so a screen reader could not distinguish active from idle.
  final String voiceIndicatorLabel;
  final String vibrationIndicatorLabel;
  final String settingsButtonLabel;

  final String statusActiveValue;
  final String statusInactiveValue;

  // T39: SettingsScreen — language selection + TTS-rate/vibration-strength
  // sliders + disabled "screen reader optimization" placeholder (T3
  // accessibility standard is still undecided, see docs/Tasks.md ⛔Open Q
  // #5, so this toggle is a disabled placeholder only).
  final String settingsTitle;
  final String settingsLanguageSectionHeader;
  final String settingsLanguageKorean;
  final String settingsLanguageEnglish;
  final String settingsVoiceVibrationSectionHeader;
  final String settingsTtsRateLabel;
  final String settingsVibrationStrengthLabel;
  final String settingsAccessibilitySectionHeader;
  final String settingsScreenReaderOptimizationLabel;
  final String settingsScreenReaderOptimizationNote;

  // T37: manual, off-by-default flashlight/torch toggle — the one code-level
  // low-light aid judged safe to ship for v1 (see docs/Tasks.md T37 and
  // docs/Tasks.md T37). Deliberately NOT automatic/always-on: the
  // user must opt in each session, so there is no unexpected battery drain
  // and no silent, unvalidated change to the camera frames the model sees
  // in normal (non-torch) use.
  final String settingsLowLightSectionHeader;
  final String settingsTorchLabel;
  final String settingsTorchNote;

  // T40: OnboardingScreen — integrates T19 (chest-mount posture guidance)
  // + T36 (first-launch legal safety disclaimer) into one first-run
  // screen. The disclaimer copy is a design draft, not legally reviewed —
  // see the "디자인 초안 문구 — 법률 검토 필요" comment on the Korean value
  // below (and its English translation), per docs/Tasks.md T40 acceptance
  // criterion (3).
  final String onboardingTitle;
  final String onboardingPostureHeading;
  final String onboardingPostureBody;
  final String onboardingDisclaimerHeading;
  final String onboardingDisclaimerBody;
  final String onboardingConfirmButton;

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
    required this.voiceIndicatorLabel,
    required this.vibrationIndicatorLabel,
    required this.settingsButtonLabel,
    required this.statusActiveValue,
    required this.statusInactiveValue,
    required this.settingsTitle,
    required this.settingsLanguageSectionHeader,
    required this.settingsLanguageKorean,
    required this.settingsLanguageEnglish,
    required this.settingsVoiceVibrationSectionHeader,
    required this.settingsTtsRateLabel,
    required this.settingsVibrationStrengthLabel,
    required this.settingsAccessibilitySectionHeader,
    required this.settingsScreenReaderOptimizationLabel,
    required this.settingsScreenReaderOptimizationNote,
    required this.settingsLowLightSectionHeader,
    required this.settingsTorchLabel,
    required this.settingsTorchNote,
    required this.onboardingTitle,
    required this.onboardingPostureHeading,
    required this.onboardingPostureBody,
    required this.onboardingDisclaimerHeading,
    required this.onboardingDisclaimerBody,
    required this.onboardingConfirmButton,
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
    voiceIndicatorLabel: '음성 안내',
    vibrationIndicatorLabel: '진동 알림',
    settingsButtonLabel: '설정',
    statusActiveValue: '켜짐',
    statusInactiveValue: '꺼짐',
    settingsTitle: '설정',
    settingsLanguageSectionHeader: '언어',
    settingsLanguageKorean: '한국어',
    settingsLanguageEnglish: '영어',
    settingsVoiceVibrationSectionHeader: '음성 및 진동',
    settingsTtsRateLabel: 'TTS 속도',
    settingsVibrationStrengthLabel: '진동 세기',
    settingsAccessibilitySectionHeader: '접근성',
    settingsScreenReaderOptimizationLabel: '화면 읽기 프로그램 최적화',
    settingsScreenReaderOptimizationNote: '아직 결정되지 않았습니다 (추후 지원 예정)',
    settingsLowLightSectionHeader: '저조도 보조',
    settingsTorchLabel: '손전등 켜기',
    settingsTorchNote: '어두운 곳에서 인식을 돕습니다. 배터리 소모가 늘어날 수 있으며, '
        '기기에 따라 지원되지 않을 수 있습니다.',
    onboardingTitle: '시작하기 전에',
    onboardingPostureHeading: '착용 방법',
    onboardingPostureBody: '목걸이형 스트랩으로 가슴 중앙에, 렌즈는 정면을 향하게 착용하세요.',
    onboardingDisclaimerHeading: '안전 안내',
    // 디자인 초안 문구 — 법률 검토 필요. 사용자가 승인한 원문 그대로 사용 (docs/Tasks.md T40).
    onboardingDisclaimerBody:
        '이 앱은 횡단보도 이탈을 감지해 음성·진동으로 알려주는 보조 도구입니다. '
        '흰지팡이·안내견·동행인의 판단을 대신하지 않으며, '
        '최종 판단과 주의는 항상 보행자 본인에게 있습니다.',
    onboardingConfirmButton: '확인했습니다',
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
    voiceIndicatorLabel: 'Voice guidance',
    vibrationIndicatorLabel: 'Vibration alert',
    settingsButtonLabel: 'Settings',
    statusActiveValue: 'On',
    statusInactiveValue: 'Off',
    settingsTitle: 'Settings',
    settingsLanguageSectionHeader: 'Language',
    settingsLanguageKorean: 'Korean',
    settingsLanguageEnglish: 'English',
    settingsVoiceVibrationSectionHeader: 'Voice & Vibration',
    settingsTtsRateLabel: 'TTS Speed',
    settingsVibrationStrengthLabel: 'Vibration Strength',
    settingsAccessibilitySectionHeader: 'Accessibility',
    settingsScreenReaderOptimizationLabel: 'Screen Reader Optimization',
    settingsScreenReaderOptimizationNote: 'Not yet decided (coming later)',
    settingsLowLightSectionHeader: 'Low-Light Assist',
    settingsTorchLabel: 'Turn on flashlight',
    settingsTorchNote: 'Helps detection in dark areas. May increase battery '
        'use, and may not be supported on all devices.',
    onboardingTitle: 'Before You Start',
    onboardingPostureHeading: 'How to Wear',
    onboardingPostureBody:
        'Wear the phone on a neck lanyard at the center of your chest, '
        'with the camera lens facing straight ahead.',
    onboardingDisclaimerHeading: 'Safety Notice',
    // Design-draft copy — pending legal review. Naturally-written English
    // translation of the user-approved Korean original above
    // (docs/Tasks.md T40); not itself a separately user-approved legal text.
    onboardingDisclaimerBody:
        'This app is an assistive tool that detects when you drift off '
        'the crosswalk and alerts you by voice and vibration. It does not '
        'replace the judgment of a white cane, guide dog, or companion — '
        'final judgment and caution always rest with the pedestrian.',
    onboardingConfirmButton: 'I Understand',
  );

  factory AppStrings.of(AppLanguage language) =>
      language == AppLanguage.en ? _en : _ko;
}
