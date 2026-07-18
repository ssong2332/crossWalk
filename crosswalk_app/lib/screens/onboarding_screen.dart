import 'package:flutter/material.dart';
import '../localization/app_strings.dart';
import '../services/feedback_service.dart';
import 'camera_screen.dart';

/// T40: first-run screen combining T19 (chest-mount posture guidance) and
/// T36 (legal safety disclaimer) into a single flow. On entry, the guidance
/// + disclaimer are read aloud via TTS (design intent); the user must press
/// the confirm button to proceed to [CameraScreen].
///
/// PERSISTENCE CAVEAT (docs/Tasks.md T40, explicitly not a blocker for this
/// task): this screen is shown on EVERY app launch, not only the first one.
/// Implementing "first-launch only" would require a persisted flag, which
/// in turn requires a new dependency (e.g. `shared_preferences`) — adding
/// new packages is out of scope per this task's constraints. If
/// first-launch-only behavior is wanted later, that is a separate decision
/// (persistence mechanism + package approval), tracked as a follow-up.
///
/// The disclaimer copy below is a DESIGN DRAFT — 법률 검토 필요 (pending
/// legal review) — see the matching comment in
/// `lib/localization/app_strings.dart` next to `onboardingDisclaimerBody`.
class OnboardingScreen extends StatefulWidget {
  // Reviewer fix (T40 follow-up): [feedback] lets the caller (normally
  // CrosswalkApp, see main.dart) share a single FeedbackService instance
  // between this screen and the CameraScreen it routes to — see the
  // ownership note on [_feedback] below for why that sharing matters. Kept
  // nullable so existing direct-construction call sites (e.g.
  // onboarding_screen_test.dart's `OnboardingScreen()`) keep working: this
  // screen falls back to owning its own instance when none is supplied.
  const OnboardingScreen({super.key, this.feedback});

  final FeedbackService? feedback;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  // T38's interactive-element accent color, reused here per the approved
  // mockup guidance (docs/Tasks.md T40 design reference).
  static const _colorAccent = Color(0xFF3AA0FF);
  static const _colorNormal = Color(0xFF35C46A);

  // T40: language is detected once here (before CameraScreen ever runs) and
  // passed forward via CameraScreen(initialLanguage:), per the task's
  // instruction to move the detection point rather than duplicate it.
  late final AppLanguage _language;
  late final AppStrings _strings;

  // Reviewer fix (T40 follow-up): shares widget.feedback (normally the one
  // FeedbackService instance owned by CrosswalkApp, see main.dart) with
  // CameraScreen instead of each screen constructing its own FlutterTts().
  // flutter_tts's MethodChannel and native speakResult slot are both
  // per-app singletons regardless of how many FlutterTts() objects exist
  // (see the ownership comment in main.dart), so two independent instances
  // would silently fight over that shared native state — sharing one
  // instance here removes that race instead of merely hiding it.
  // `_ownsFeedback` tracks whether this screen created its own fallback
  // instance (true only when no [FeedbackService] was supplied, e.g. in
  // onboarding_screen_test.dart's direct `OnboardingScreen()` construction);
  // only an owned instance is disposed by this screen (see dispose() below)
  // — a shared instance must outlive this screen since CameraScreen keeps
  // using it after pushReplacement.
  late final FeedbackService _feedback;
  late final bool _ownsFeedback;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    _feedback = widget.feedback ?? FeedbackService();
    _ownsFeedback = widget.feedback == null;
    _language = resolveAppLanguage(WidgetsBinding.instance.platformDispatcher.locale);
    _strings = AppStrings.of(_language);
    _initAndSpeak();
  }

  Future<void> _initAndSpeak() async {
    await _feedback.init(language: _language);
    if (!mounted) return;
    // Design intent: the posture guidance and legal disclaimer are both
    // read aloud on entry, in the same order they appear on screen.
    await _feedback.speak(
      '${_strings.onboardingPostureBody} ${_strings.onboardingDisclaimerBody}',
    );
  }

  void _confirm() {
    if (_navigated) return;
    _navigated = true;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => CameraScreen(
          initialLanguage: _language,
          feedback: _feedback,
        ),
      ),
    );
  }

  @override
  void dispose() {
    // Reviewer fix (T40 follow-up): only dispose the instance this screen
    // created itself. A shared instance (the common case, passed in from
    // CrosswalkApp) is still in use by the CameraScreen this screen just
    // navigated to via pushReplacement — disposing it here would tear down
    // the FlutterTts session CameraScreen depends on.
    if (_ownsFeedback) {
      _feedback.dispose();
    }
    super.dispose();
  }

  Widget _buildSection({
    required IconData icon,
    required Color iconColor,
    required String heading,
    required String body,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor, size: 22),
              const SizedBox(width: 8),
              Text(
                heading,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            body,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 15,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _strings.onboardingTitle,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 20),
                    _buildSection(
                      icon: Icons.checkroom_outlined,
                      iconColor: _colorNormal,
                      heading: _strings.onboardingPostureHeading,
                      body: _strings.onboardingPostureBody,
                    ),
                    _buildSection(
                      icon: Icons.info_outline,
                      iconColor: _colorAccent,
                      heading: _strings.onboardingDisclaimerHeading,
                      body: _strings.onboardingDisclaimerBody,
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _confirm,
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                    backgroundColor: _colorAccent,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(
                    _strings.onboardingConfirmButton,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
