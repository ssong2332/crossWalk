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
    // Design intent: the legal disclaimer and posture guidance are both
    // read aloud on entry, in the same order they appear on screen (legal
    // notice card first, per the imported Claude Design layout).
    await _feedback.speak(
      '${_strings.onboardingDisclaimerBody} ${_strings.onboardingPostureBody}',
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

  // Claude Design import (claude.ai/design project 453fb831…, "Crosswalk
  // App"): plain content card — used for the legal-notice and wear-guide
  // sections. Unlike the previous version, the heading is a bare title (no
  // leading icon) with an optional trailing badge chip, matching the
  // imported design's card structure.
  Widget _buildCard({
    required String heading,
    Widget? badge,
    required Widget child,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              Text(
                heading,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (badge != null) badge,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _buildDraftBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFFFE9A8),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _strings.onboardingDisclaimerDraftBadge,
        style: const TextStyle(
          color: Color(0xFF3A2C00),
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  // Simplified stand-in for the imported design's chest-mount wear-angle
  // line drawing — an icon-based diagram rather than a pixel-accurate
  // recreation of the original SVG-style sketch, judged sufficient to
  // convey "phone worn on a chest lanyard, angled slightly down".
  Widget _buildWearDiagram() {
    return Column(
      children: [
        SizedBox(
          height: 96,
          child: Center(
            child: Transform.rotate(
              angle: 0.14,
              child: Container(
                width: 62,
                height: 88,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white70, width: 2),
                ),
                child: Column(
                  children: [
                    const SizedBox(height: 8),
                    Container(
                      width: 22,
                      height: 3,
                      decoration: BoxDecoration(
                        color: Colors.white38,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Icon(Icons.camera_alt_outlined,
                        color: _colorAccent, size: 18),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '[ ${_strings.onboardingPosturePlaceholder} ]',
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 11,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  Widget _buildTtsNoticeChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _colorAccent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.campaign_outlined, color: _colorAccent, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _strings.onboardingTtsNotice,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
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
                      _strings.onboardingEyebrow,
                      style: const TextStyle(
                        color: _colorAccent,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _strings.onboardingTitle,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 20),
                    _buildCard(
                      heading: _strings.onboardingDisclaimerHeading,
                      badge: _buildDraftBadge(),
                      child: Text(
                        _strings.onboardingDisclaimerBody,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 15,
                          height: 1.5,
                        ),
                      ),
                    ),
                    _buildCard(
                      heading: _strings.onboardingPostureHeading,
                      child: Column(
                        children: [
                          _buildWearDiagram(),
                          const SizedBox(height: 12),
                          Text(
                            _strings.onboardingPostureBody,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _buildTtsNoticeChip(),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _confirm,
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                    backgroundColor: _colorAccent,
                    // Contrast fix (Claude Design spec §1): #3AA0FF against
                    // white text is under WCAG AA; dark navy text on this
                    // accent color measures 6.49:1.
                    foregroundColor: const Color(0xFF08182A),
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
