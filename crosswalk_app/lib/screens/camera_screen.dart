import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/classifier.dart';
import '../services/feedback_service.dart';
import '../localization/app_strings.dart';
import 'settings_screen.dart';

class CameraScreen extends StatefulWidget {
  // T40: language is now detected once in OnboardingScreen (which runs
  // before this screen) and passed forward via [initialLanguage], so the
  // user only sees one locale-detection point. Kept optional/nullable so
  // existing direct-construction call sites (e.g. widget tests that build
  // `CameraScreen()` on its own, without going through OnboardingScreen)
  // keep working unchanged — this screen still falls back to detecting the
  // system locale itself when no language is supplied.
  //
  // Reviewer fix (T40 follow-up): [feedback] lets OnboardingScreen (via
  // main.dart's CrosswalkApp) share its single FeedbackService instance
  // with this screen instead of each screen constructing its own
  // FlutterTts() — see the ownership comment on [_feedback] below for why.
  // Kept nullable for the same backward-compatibility reason as
  // [initialLanguage]: existing direct-construction call sites (e.g.
  // camera_screen_test.dart's `CameraScreen()`) keep working, falling back
  // to an owned instance.
  const CameraScreen({super.key, this.initialLanguage, this.feedback});

  final AppLanguage? initialLanguage;
  final FeedbackService? feedback;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  CameraController? _controller;
  final Classifier _classifier = Classifier();

  // Reviewer fix (T40 follow-up): uses widget.feedback (normally the single
  // FeedbackService instance owned by CrosswalkApp and shared via
  // OnboardingScreen) instead of always constructing a new one — see
  // main.dart's ownership comment for why sharing matters. `_ownsFeedback`
  // tracks whether this screen created its own fallback instance (true only
  // when no [FeedbackService] was supplied, e.g. camera_screen_test.dart's
  // direct `CameraScreen()` construction); only an owned instance is
  // disposed by this screen (see dispose() below).
  late final FeedbackService _feedback;
  late final bool _ownsFeedback;

  // Detected at startup from the system locale (T34), and changeable
  // in-session from SettingsScreen (T39) via _onLanguageChanged below.
  late AppLanguage _language;
  late AppStrings _strings;

  late String _statusLabel;
  double _confidence = 0.0;

  // Claude Design 1d: 무판정은 6번째 상태다(전체의 약 6%). 이전 구현은
  // `processFrame`이 null을 돌려주면 **아무것도 하지 않아** 직전 상태가 화면에
  // 그대로 남았다 — 모르는 것을 아는 척하는 셈이었다.
  //
  // `processFrame`은 스로틀로 건너뛴 프레임에서도 null을 돌려주므로 단일
  // null만으로는 "임계값 미달"과 구분할 수 없다. 그래서 **지속 시간**으로
  // 판단한다: 마지막 성공 판정 이후 3초가 지나면 무판정으로 표시한다.
  // 3초는 디자인 1f의 polite live region 낭독 조건과 같은 값이다.
  static const _noCallAfter = Duration(seconds: 3);
  DateTime? _lastResultAt;
  bool _noCall = false;
  Timer? _noCallTicker;
  bool _isProcessing = false;
  bool _hasError = false;
  bool _isInitializing = false;
  bool _permissionPermanentlyDenied = false;

  // T37: manual, off-by-default low-light assist (flashlight/torch).
  // Reset to false on every _initCamera() call because a freshly created
  // CameraController always starts with flash off regardless of the
  // previous controller's state (e.g. after app resume) — this field must
  // track the real hardware state, not persist a stale "on" value across a
  // controller that no longer exists.
  bool _torchEnabled = false;

  // Claude Design "Crosswalk Guide" 1e 팔레트 (Industry 디자인 시스템 기반).
  //
  // 이전 팔레트는 front=녹색 / left=빨강 / right=주황이었다. 빨강과 주황의
  // 상호 대비가 1.50:1이라 적록색약(남성 약 8%)에게 **좌우가 같은 색**으로
  // 보였다 — 안전상 절대 헷갈리면 안 되는 두 방향이 그랬다.
  //
  // 새 팔레트는 스틸(청)–앰버(황) 축 하나만 쓴다. 이 축은 protan/deutan/tritan
  // 세 유형 모두에서 명도차가 유지된다. **좌·우에 같은 색(앰버)을 쓰고**,
  // 방향은 화살표(형태) · 좌우 정렬(위치) · 문구(텍스트) 세 겹으로 전달한다.
  // 색이 전부 사라져도 형태와 위치만으로 여섯 상태가 구분되어야 한다.
  //
  // 배경 #0E1013 대비 (계산값): 본문 15.8:1 / 보조 7.4:1 / 스틸 9.9:1 /
  // 앰버 9.6:1 / 무판정 윤곽 11.6:1.
  static const _colorBg = Color(0xFF0E1013);
  static const _colorSurface = Color(0xFF171A1D);
  static const _colorText = Color(0xFFF1F3F4);
  static const _colorTextDim = Color(0xFFA9B0B6);
  /// 정렬(front/approach) · 크롬 공통색.
  static const _colorSteel = Color(0xFFA8CDE8);
  /// 이탈(left/right) 공통색. **방향을 구분하지 않는다** — 종류만 말한다.
  static const _colorAmber = Color(0xFFF2B14A);
  /// 무판정 윤곽.
  static const _colorNoCall = Color(0xFFCBD1D6);
  static const _colorAccent = _colorSteel;
  static const _colorNone = Color(0xFFA9B0B6);
  static const _colorApproach = _colorSteel;
  static const _colorFront = _colorSteel;
  static const _colorLeft = _colorAmber;
  static const _colorRight = _colorAmber;
  /// 스틸 배경 위 텍스트 (CTA).
  static const _colorAccentOnText = Color(0xFF08182A);
  static const _colorWarning = _colorAmber;

  // Claude Design import: low-light / mount-tilt warning banners are new UI
  // components from the imported design. NEITHER is wired to a real sensor
  // trigger — T37 already investigated and rejected automatic low-light
  // detection (no reliable ambient-light API), and tilt/angle detection has
  // never been investigated at all. These fields exist so the banner widget
  // can be shown once a real trigger is decided; they are never set to true
  // anywhere in this file today, so the banners are permanently hidden in
  // the shipped app until that follow-up decision is made.
  final bool _warnLowLight = false;
  final bool _warnTilt = false;

  static const _labelColors = {
    'front': _colorFront,
    'left': _colorLeft,
    'right': _colorRight,
    'none': _colorNone,
    'approach': _colorApproach,
  };

  Map<String, String> get _labelText => {
        'front': _strings.labelFront,
        'left': _strings.labelLeft,
        'right': _strings.labelRight,
        'none': _strings.labelNone,
        'approach': _strings.labelApproach,
      };


  // T41: direction-guidance corridor overlay animation state.
  //
  // HONESTY CONSTRAINT (docs/Tasks.md T41; class count updated by T51):
  // `Classifier` is a 5-class classifier
  // (none/approach/front/left/right + confidence) with NO coordinate/geometry
  // output — it never detects an actual crosswalk's real-world position.
  // Everything below converts the classification result into a purely
  // symbolic directional guide (a "guidance corridor"), NOT a rendering of a
  // detected object. All names in this section intentionally use
  // "guidance", never "detection"/"detected"/"recognized".
  //
  // `_guidanceLabel` tracks the last classification label this animation
  // was driven from (front/left/right), so [_updateGuidanceTarget] can tell
  // whether the label actually changed before re-triggering the animation.
  String _guidanceLabel = 'front';
  late final AnimationController _guidanceAnimController;
  late Tween<double> _guidanceCurveTween;
  late ColorTween _guidanceColorTween;

  @override
  void initState() {
    super.initState();
    // 무판정 감시: 마지막 성공 판정이 3초 이상 지나면 화면에 무판정을 표시한다.
    _noCallTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      final last = _lastResultAt;
      final stale = last == null
          ? false
          : DateTime.now().difference(last) >= _noCallAfter;
      if (stale != _noCall && mounted) setState(() => _noCall = stale);
    });
    _feedback = widget.feedback ?? FeedbackService();
    _ownsFeedback = widget.feedback == null;
    _language = widget.initialLanguage ??
        resolveAppLanguage(WidgetsBinding.instance.platformDispatcher.locale);
    _strings = AppStrings.of(_language);
    _statusLabel = _strings.initializing;
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _guidanceAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _guidanceCurveTween = Tween<double>(begin: 0.0, end: 0.0);
    _guidanceColorTween = ColorTween(begin: _colorFront, end: _colorFront);
    _initCamera();
  }

  // T41: -1.0 (guidance curves left) .. 0.0 (straight) .. 1.0 (guidance
  // curves right). Derived purely from the classifier's front/left/right
  // label — NOT a measured real-world angle of any physical feature.
  double _guidanceCurveForLabel(String label) {
    switch (label) {
      case 'left':
        return -1.0;
      case 'right':
        return 1.0;
      default:
        return 0.0;
    }
  }

  // T41: called whenever a new classification label arrives (_onFrame).
  // Restarts the guidance animation from the corridor's current on-screen
  // position/color toward the new label's target, so state changes read as
  // a smooth transition instead of a jump cut.
  void _updateGuidanceTarget(String label) {
    if (label == _guidanceLabel) return;
    final currentCurve = _guidanceCurveTween.evaluate(_guidanceAnimController);
    final currentColor =
        _guidanceColorTween.evaluate(_guidanceAnimController) ?? _colorFront;
    _guidanceLabel = label;
    _guidanceCurveTween = Tween<double>(
      begin: currentCurve,
      end: _guidanceCurveForLabel(label),
    );
    _guidanceColorTween = ColorTween(
      begin: currentColor,
      end: _labelColors[label] ?? _colorFront,
    );
    _guidanceAnimController
      ..stop()
      ..value = 0
      ..forward();
  }


  Future<void> _initCamera() async {
    if (_isInitializing) return;
    _isInitializing = true;

    try {
      setState(() {
        _hasError = false;
        _permissionPermanentlyDenied = false;
        _torchEnabled = false;
        _statusLabel = _strings.initializing;
      });

      try {
        // TTS를 먼저 초기화해야 이후 오류 발생 시 음성 안내 가능
        await _feedback.init(language: _language);

        final status = await Permission.camera.request();
        if (!status.isGranted) {
          if (status.isPermanentlyDenied) {
            await _feedback.announceError(
              _strings.cameraPermissionPermanentlyDeniedAnnouncement,
            );
            if (mounted) {
              setState(() {
                _hasError = true;
                _permissionPermanentlyDenied = true;
                _statusLabel = _strings.cameraPermissionRequiredSettingsLabel;
              });
            }
          } else {
            await _feedback
                .announceError(_strings.cameraPermissionRequiredAnnouncement);
            if (mounted) {
              setState(() {
                _hasError = true;
                _statusLabel = _strings.cameraPermissionRequiredLabel;
              });
            }
          }
          return;
        }

        setState(() => _statusLabel = _strings.loadingModel);
        await _classifier.init();

        setState(() => _statusLabel = _strings.connectingCamera);
        final cameras = await availableCameras();
        if (cameras.isEmpty) {
          await _feedback.announceError(_strings.cameraNotFoundAnnouncement);
          if (mounted) {
            setState(() {
              _hasError = true;
              _statusLabel = _strings.cameraNotFoundLabel;
            });
          }
          return;
        }

        final back = cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cameras.first,
        );

        _controller = CameraController(
          back,
          ResolutionPreset.medium,
          enableAudio: false,
          imageFormatGroup: ImageFormatGroup.yuv420,
        );

        await _controller!.initialize();
        await _controller!.lockCaptureOrientation();

        // T37 (low-light v1, investigation result): explicitly request auto
        // exposure. NOTE this is a documented no-op on the currently locked
        // Android implementation (camera_android_camerax 0.6.19+1 hardcodes
        // `ExposureMode.auto` at init — verified directly from that
        // package's source, `android_camera_camerax.dart:485`), so it
        // changes no runtime behavior today. Kept explicit rather than
        // relying on the implicit platform default, and as a defensive
        // no-op ahead of a future iOS build (T33, currently paused). A
        // real brightness-boosting change (e.g. a fixed positive
        // `setExposureOffset`) was investigated and deliberately NOT added:
        // it would apply to every frame (day and night alike, since this
        // package exposes no ambient-light reading to scope it to
        // low-light only), and the shipped model has not been validated
        // against any exposure shift — the same train/inference-mismatch
        // risk already found for other unvalidated preprocessing changes
        // (see docs/Tasks.md T1/T35). See docs/Tasks.md T37 for the full
        // investigation.
        try {
          await _controller!.setExposureMode(ExposureMode.auto);
        } catch (_) {
          // 일부 기기/플랫폼에서 노출 모드 변경이 지원되지 않을 수 있음 — 무시하고 계속 진행
        }

        if (!mounted) return;

        _controller!.startImageStream(_onFrame);
        setState(() => _statusLabel = _strings.detecting);
      } on ModelIntegrityException {
        await _feedback.announceError(_strings.modelCorruptedAnnouncement);
        if (mounted) {
          setState(() {
            _hasError = true;
            _statusLabel = _strings.modelCorruptedLabel;
          });
        }
      } catch (e) {
        await _feedback.announceError(_strings.detectionErrorAnnouncement);
        if (mounted) {
          setState(() {
            _hasError = true;
            _statusLabel = _strings.detectionErrorLabel;
          });
        }
      }
    } finally {
      _isInitializing = false;
    }
  }

  // T37: manual, off-by-default flashlight/torch toggle — see docs/Tasks.md
  // T37 for why this (and not an automatic/always-on
  // torch or a preprocessing brightness correction) was chosen as the
  // safe, v1 low-light aid. Fire-and-forget from SettingsScreen, matching
  // this app's existing pattern for other in-session-only settings
  // (updateSpeechRate/updateVibrationDuration in feedback_service.dart):
  // on failure (e.g. device/camera has no torch), the state is silently
  // left unchanged rather than surfaced as an error, since this is a
  // best-effort convenience feature, not a safety-critical path.
  Future<void> _setTorch(bool enabled) async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    try {
      await _controller!
          .setFlashMode(enabled ? FlashMode.torch : FlashMode.off);
      if (mounted) setState(() => _torchEnabled = enabled);
    } catch (_) {
      // 기기가 손전등 제어를 지원하지 않을 수 있음 — 상태 변경 없이 무시
    }
  }

  void _onFrame(CameraImage image) {
    if (_isProcessing) return;
    _isProcessing = true;

    final result = _classifier.processFrame(image);
    if (result != null) {
      _feedback.alert(result.label);
      if (mounted) {
        setState(() {
          _statusLabel = _labelText[result.label] ?? result.label;
          _confidence = result.confidence;
          _lastResultAt = DateTime.now();
          _noCall = false;
        });
        // T41: drive the guidance corridor overlay from the same
        // classification result — see _updateGuidanceTarget's doc comment
        // for the honesty constraint this must respect.
        _updateGuidanceTarget(result.label);
      }
    }

    _isProcessing = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      if (_controller != null && _controller!.value.isInitialized) {
        _controller!.dispose();
      }
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    _noCallTicker?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    _guidanceAnimController.dispose();
    _controller?.dispose();
    _classifier.dispose();
    // Reviewer fix (T40 follow-up): only dispose the instance this screen
    // created itself. A shared instance is owned by CrosswalkApp (see
    // main.dart) and must outlive this screen — e.g. across
    // didChangeAppLifecycleState's resumed -> _initCamera() re-entry, which
    // does not recreate this screen.
    if (_ownsFeedback) {
      _feedback.dispose();
    }
    super.dispose();
  }

  // Claude Design 1a: 상태 색·아이콘 판단은 `_fieldColor`/`StateFieldPainter`로
  // 옮겼다. 이전 `_statusColor`/`_statusIcon`은 표시 문자열을 되짚어 상태를
  // 역추론했는데(`_statusLabel == _strings.labelFront` 비교), 문구가 바뀌면
  // 조용히 깨지는 구조였다. 지금은 분류 라벨(`_guidanceLabel`)을 직접 쓴다.

  bool get _isLoading =>
      !_hasError && (_controller == null || !_controller!.value.isInitialized);

  // T38: 음성/진동 활성 상태를 나타내는 아이콘 pill. 활성 시 강조색(#3aa0ff)
  // 배경 + 흰 아이콘, 비활성 시 흐린 테두리만 있는 투명 배경으로 구분.
  Widget _buildStatusPill({
    required IconData icon,
    required bool active,
    required String semanticLabel,
  }) {
    return Semantics(
      label: semanticLabel,
      // Reviewer fix: announce the actual on/off state as the Semantics
      // `value` (read after the label, e.g. "음성 안내, 켜짐"), so a screen
      // reader user can tell an active indicator from an idle one — the
      // label text alone no longer implies state.
      value: active ? _strings.statusActiveValue : _strings.statusInactiveValue,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? _colorAccent : Colors.black.withValues(alpha: 0.35),
          border: Border.all(
            color: active ? _colorAccent : Colors.white38,
            width: 1.5,
          ),
        ),
        child: Icon(
          icon,
          size: 20,
          color: active ? Colors.white : Colors.white38,
        ),
      ),
    );
  }

  // T39: 언어가 SettingsScreen에서 바뀌면 CameraScreen의 표시 언어(_language/
  // _strings)와 FeedbackService 양쪽에 반영한다. FeedbackService 자체 업데이트는
  // SettingsScreen이 직접 호출하므로(feedback.updateLanguage), 여기서는 이
  // 화면의 표시 상태만 갱신하면 된다.
  void _onLanguageChanged(AppLanguage language) {
    if (!mounted) return;
    setState(() {
      _language = language;
      _strings = AppStrings.of(language);
    });
  }

  // Claude Design import: full-screen centered error card, replacing the
  // previous red-tint overlay + error text crammed into the bottom glass
  // tray. Same underlying error logic/state as before (ordinary vs
  // permanently-denied permission, retry vs "open settings" CTA) — only the
  // presentation changed, matching the imported design's dedicated error
  // state (icon circle, title, body, single 52dp CTA on a scrim
  // background).
  Widget _buildErrorCard() {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.94),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.fromBorderSide(
                      BorderSide(color: _colorLeft, width: 3),
                    ),
                  ),
                  child: const Icon(Icons.priority_high,
                      color: _colorLeft, size: 30),
                ),
                const SizedBox(height: 16),
                Text(
                  _statusLabel,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isInitializing
                        ? null
                        : (_permissionPermanentlyDenied
                            ? openAppSettings
                            : _initCamera),
                    icon: Icon(
                      _permissionPermanentlyDenied
                          ? Icons.settings
                          : Icons.refresh,
                    ),
                    label: Text(
                      _permissionPermanentlyDenied
                          ? _strings.openSettingsButton
                          : _strings.retryButton,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      backgroundColor: _colorAccent,
                      foregroundColor: _colorAccentOnText,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Claude Design import: low-light / mount-tilt warning banner. See the
  // "UI ONLY" comment on `_warnLowLight`/`_warnTilt` above — currently
  // unreachable in the shipped app (both fields are always false), kept as
  // a ready-to-use component for when a real trigger is decided.
  Widget _buildWarningBanner({required String title, required String body}) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _colorWarning,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Semantics(
        liveRegion: true,
        label: '$title. $body',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.warning_rounded, color: Color(0xFF3A2C00), size: 20),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Color(0xFF3A2C00),
                          fontSize: 13,
                          fontWeight: FontWeight.w700)),
                  Text(body,
                      style: const TextStyle(
                          color: Color(0xFF5C4A1F), fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // T38/T39: 설정 화면 진입 버튼. SettingsScreen으로 라우팅한다.
  Widget _buildSettingsButton() {
    return Semantics(
      label: _strings.settingsButtonLabel,
      button: true,
      child: Material(
        color: Colors.black.withValues(alpha: 0.35),
        shape: const CircleBorder(
          side: BorderSide(color: Colors.white38, width: 1.5),
        ),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsScreen(
                  feedback: _feedback,
                  language: _language,
                  onLanguageChanged: _onLanguageChanged,
                  torchEnabled: _torchEnabled,
                  onTorchChanged: _setTorch,
                ),
              ),
            );
          },
          child: const Padding(
            // Reviewer fix: 8 -> 14 so the tappable circle (icon 20 + 2x
            // padding) grows from 36dp to ~48dp, meeting the recommended
            // minimum touch-target size for an accessibility-focused app.
            padding: EdgeInsets.all(14),
            child:
                Icon(Icons.settings_outlined, size: 20, color: Colors.white70),
          ),
        ),
      ),
    );
  }

  /// 현재 표시할 상태 키. 무판정이 최우선이다 — 모르는 것을 아는 척하지 않는다.
  String get _fieldState {
    if (_hasError) return 'error';
    if (_isLoading) return 'loading';
    if (_noCall) return 'nocall';
    return _guidanceLabel;
  }

  Color get _fieldColor {
    switch (_fieldState) {
      case 'left':
      case 'right':
        return _colorAmber;
      case 'front':
      case 'approach':
        return _colorSteel;
      case 'nocall':
        return _colorNoCall;
      default:
        return _colorNone;
    }
  }

  /// 화면 제목 — 관측형 문장(Claude Design 1g의 C안). 화면은 보호자·심사자가
  /// 읽으므로 단정하지 않는 관측 문장이 정직하다. 음성은 지시형(B안)으로
  /// 따로 나간다("오른쪽으로 조금").
  String get _fieldHeadline {
    switch (_fieldState) {
      case 'nocall':
        return _strings.labelNoCall;
      case 'loading':
      case 'error':
        return _statusLabel;
      default:
        return _labelText[_fieldState] ?? _statusLabel;
    }
  }

  /// 보조 한 줄 — 화살표와 같은 편, 즉 **가야 할 방향**.
  String get _fieldSubline {
    if (_fieldState == 'nocall') return _strings.noCallBody;
    return _strings.cameraStateDescriptions[_fieldState] ?? '';
  }

  @override
  Widget build(BuildContext context) {
    // Claude Design 1l: 200%에서 살아남는 방법은 크기를 줄이는 것이 아니라
    // **내용을 버리는 것**이다. 확대 시 확신도 같은 2차 정보는 화면에서 빠지고
    // 음성으로만 남는다. 어떤 컨테이너에도 고정 높이를 주지 않는다.
    final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
    final dense = scale > 1.5;
    final color = _fieldColor;

    return Scaffold(
      backgroundColor: _colorBg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── 상단 크롬: 음성/진동 표시 + 설정 ──────────────────────────
            if (!_hasError)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        ValueListenableBuilder<bool>(
                          valueListenable: _feedback.isSpeaking,
                          builder: (context, active, _) => _buildStatusPill(
                            icon: Icons.volume_up,
                            active: active,
                            semanticLabel: _strings.voiceIndicatorLabel,
                          ),
                        ),
                        const SizedBox(width: 8),
                        ValueListenableBuilder<bool>(
                          valueListenable: _feedback.isVibrating,
                          builder: (context, active, _) => _buildStatusPill(
                            icon: Icons.vibration,
                            active: active,
                            semanticLabel: _strings.vibrationIndicatorLabel,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _buildSettingsButton(),
                      ],
                    ),
                    if (_warnLowLight)
                      _buildWarningBanner(
                        title: _strings.warnLowLightTitle,
                        body: _strings.warnLowLightBody,
                      ),
                    if (_warnTilt)
                      _buildWarningBanner(
                        title: _strings.warnTiltTitle,
                        body: _strings.warnTiltBody,
                      ),
                  ],
                ),
              ),

            // ── 상태 필드 ────────────────────────────────────────────────
            //
            // Claude Design 1a(권장안): **카메라 프리뷰를 렌더링하지 않는다.**
            // 주 사용자는 화면을 보지 않고, 프리뷰를 깔면 배경이 매 프레임 바뀌어
            // 그 위 텍스트의 대비를 보장할 수 없다(흰 줄무늬 위와 아스팔트 위가
            // 다르다). 카메라 스트림은 그대로 돌아가며 분류에 쓰인다 —
            // 화면에만 그리지 않는다.
            //
            // 형태 + 위치가 방향을 말하고, 색은 "이탈인가 아닌가"만 말한다.
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: _isLoading
                    ? const Center(
                        child: SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: _colorSteel,
                          ),
                        ),
                      )
                    : RepaintBoundary(
                        child: CustomPaint(
                          size: Size.infinite,
                          painter: StateFieldPainter(
                            state: _fieldState,
                            color: color,
                          ),
                        ),
                      ),
              ),
            ),

            // ── 하단 판독부 ──────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Claude Design 1f: 상태 변화는 사용자가 찾아 들어가지 않아도
                  // 자동으로 낭독되어야 한다. 확신도 숫자는 낭독하지 않는다 —
                  // 걷는 중에 "0.71"은 판단을 돕지 않고 소음이 된다.
                  Semantics(
                    liveRegion: true,
                    label: _fieldSubline.isEmpty
                        ? _fieldHeadline
                        : '$_fieldHeadline. $_fieldSubline',
                    child: ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _fieldHeadline,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: color,
                              fontSize: 30,
                              height: 1.15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (_fieldSubline.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                _fieldSubline,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: _colorText,
                                  fontSize: 20,
                                  height: 1.2,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  // 2차 정보 — 200% 확대 시 화면에서 버린다 (음성으로만 남는다).
                  if (!dense && _confidence > 0 && !_hasError) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        '${_strings.confidenceLabel} '
                        '${(_confidence * 100).toStringAsFixed(0)}%',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: _colorTextDim, fontSize: 14),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: LayoutBuilder(
                        builder: (context, constraints) => Stack(
                          children: [
                            Container(
                              height: 3,
                              width: constraints.maxWidth,
                              color: _colorSurface,
                            ),
                            Container(
                              height: 3,
                              width: constraints.maxWidth *
                                  _confidence.clamp(0.0, 1.0),
                              color: color,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Text(
                      _strings.cameraGuidanceDisclaimer,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: _colorTextDim, fontSize: 13, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),

            if (_hasError) _buildErrorCard(),
          ],
        ),
      ),
    );
  }
}

/// 상태를 **형태와 위치**로 그린다 — 색이 전부 사라져도 여섯 상태가 구분되도록.
///
/// 정직성 제약: `Classifier`는 좌표·기하 정보를 내지 않는다. 여기 그려지는
/// 화살표는 실제로 감지된 횡단보도의 위치가 아니라 **분류 결과를 옮긴 안내
/// 기호**다. 화살표는 항상 **가야 할 방향**을 가리키고, 문구가 틀어진 방향을
/// 말한다 (Claude Design 1d).
class StateFieldPainter extends CustomPainter {
  const StateFieldPainter({required this.state, required this.color});

  /// 'front' | 'left' | 'right' | 'approach' | 'none' | 'nocall' | 'error'
  final String state;
  final Color color;

  static const _pi = 3.1415926535897932;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    final unit = size.shortestSide * 0.30;
    switch (state) {
      case 'front':
        _arrow(canvas, stroke, Offset(size.width / 2, size.height / 2), unit,
            -_pi / 2);
        break;
      case 'left':
        // 왼쪽으로 틀어졌다 -> 가야 할 방향은 오른쪽. 위치도 우측 정렬.
        _arrow(canvas, stroke, Offset(size.width * 0.70, size.height / 2), unit,
            0);
        break;
      case 'right':
        _arrow(canvas, stroke, Offset(size.width * 0.30, size.height / 2), unit,
            _pi);
        break;
      case 'approach':
        _thresholdBar(canvas, stroke, size, unit);
        break;
      case 'nocall':
        _hatchedSquare(canvas, stroke, size, unit);
        break;
      default:
        _dashedCircle(canvas, stroke, size, unit);
    }
  }

  void _arrow(Canvas canvas, Paint p, Offset c, double unit, double rot) {
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(rot);
    canvas.drawLine(Offset(-unit, 0), Offset(unit, 0), p);
    canvas.drawLine(Offset(unit, 0), Offset(unit - unit * 0.5, -unit * 0.5), p);
    canvas.drawLine(Offset(unit, 0), Offset(unit - unit * 0.5, unit * 0.5), p);
    canvas.restore();
  }

  /// 문턱 막대 — "여기서부터 횡단보도" (중앙 상단).
  void _thresholdBar(Canvas canvas, Paint p, Size size, double unit) {
    final y = size.height * 0.34;
    final cx = size.width / 2;
    canvas.drawLine(Offset(cx - unit, y), Offset(cx + unit, y), p);
    final thin = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = p.color.withValues(alpha: 0.55);
    for (var i = 1; i <= 3; i++) {
      final yy = y + i * (unit * 0.32);
      final w = unit * (1 - i * 0.2);
      canvas.drawLine(Offset(cx - w, yy), Offset(cx + w, yy), thin);
    }
  }

  /// 사선 해칭 사각 — "판정 없음". 채우지 않는다: 비어 있음을 보여준다.
  void _hatchedSquare(Canvas canvas, Paint p, Size size, double unit) {
    final r = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: unit * 1.8,
      height: unit * 1.8,
    );
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..color = p.color;
    canvas.drawRect(r, outline);
    canvas.save();
    canvas.clipRect(r);
    final hatch = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = p.color.withValues(alpha: 0.6);
    for (var x = r.left - r.height; x < r.right + r.height; x += 16) {
      canvas.drawLine(Offset(x, r.bottom), Offset(x + r.height, r.top), hatch);
    }
    canvas.restore();
  }

  /// 점선 원 — "횡단보도 없음".
  void _dashedCircle(Canvas canvas, Paint p, Size size, double unit) {
    final c = Offset(size.width / 2, size.height / 2);
    final dash = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round
      ..color = p.color;
    const segments = 16;
    for (var i = 0; i < segments; i++) {
      final start = (i * 2 * _pi) / segments;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: unit),
        start,
        (2 * _pi / segments) * 0.55,
        false,
        dash,
      );
    }
  }

  @override
  bool shouldRepaint(covariant StateFieldPainter oldDelegate) {
    return oldDelegate.state != state || oldDelegate.color != color;
  }
}
