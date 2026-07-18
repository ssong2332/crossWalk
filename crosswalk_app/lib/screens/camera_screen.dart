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

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
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
  bool _isProcessing = false;
  bool _hasError = false;
  bool _isInitializing = false;
  bool _permissionPermanentlyDenied = false;

  // T38: signal palette matching real pedestrian-crossing signal colors
  // (approved design), replacing the previous arbitrary Material defaults.
  static const _colorFront = Color(0xFF35C46A);
  static const _colorLeft = Color(0xFFFF5A5F);
  static const _colorRight = Color(0xFFFF9F40);
  // Non-status interactive elements (buttons, progress indicators, etc.).
  static const _colorAccent = Color(0xFF3AA0FF);

  static const _labelColors = {
    'front': _colorFront,
    'left':  _colorLeft,
    'right': _colorRight,
  };

  Map<String, String> get _labelText => {
    'front': _strings.labelFront,
    'left':  _strings.labelLeft,
    'right': _strings.labelRight,
  };

  static const _labelIcons = {
    'front': Icons.check_circle,
    'left':  Icons.chevron_left,
    'right': Icons.chevron_right,
  };

  @override
  void initState() {
    super.initState();
    _feedback = widget.feedback ?? FeedbackService();
    _ownsFeedback = widget.feedback == null;
    _language = widget.initialLanguage ??
        resolveAppLanguage(WidgetsBinding.instance.platformDispatcher.locale);
    _strings = AppStrings.of(_language);
    _statusLabel = _strings.initializing;
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _initCamera();
  }

  Future<void> _initCamera() async {
    if (_isInitializing) return;
    _isInitializing = true;

    try {
      setState(() {
        _hasError = false;
        _permissionPermanentlyDenied = false;
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
            await _feedback.announceError(_strings.cameraPermissionRequiredAnnouncement);
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
        });
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
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
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

  Color get _statusColor {
    if (_hasError) return Colors.red;
    if (_statusLabel == _strings.labelFront) return _colorFront;
    if (_statusLabel == _strings.labelLeft) return _colorLeft;
    if (_statusLabel == _strings.labelRight) return _colorRight;
    return Colors.grey;
  }

  IconData? get _statusIcon {
    if (_hasError) return Icons.error_outline;
    if (_statusLabel == _strings.labelFront) return _labelIcons['front'];
    if (_statusLabel == _strings.labelLeft) return _labelIcons['left'];
    if (_statusLabel == _strings.labelRight) return _labelIcons['right'];
    return null;
  }

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
                ),
              ),
            );
          },
          child: const Padding(
            // Reviewer fix: 8 -> 14 so the tappable circle (icon 20 + 2x
            // padding) grows from 36dp to ~48dp, meeting the recommended
            // minimum touch-target size for an accessibility-focused app.
            padding: EdgeInsets.all(14),
            child: Icon(Icons.settings_outlined, size: 20, color: Colors.white70),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final statusIcon = _statusIcon;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (_controller != null && _controller!.value.isInitialized)
            Positioned.fill(
              child: CameraPreview(_controller!),
            ),

          // 오류 상태: 화면 전체를 반투명 빨간 오버레이로 덮어 시각적으로 명확히 표시
          if (_hasError)
            Positioned.fill(
              child: ColoredBox(color: Colors.red.withOpacity(0.25)),
            ),

          // T38: top-right status pills (voice/vibration active) + settings
          // entry button (gear icon).
          Positioned(
            top: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
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
              ),
            ),
          ),

          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              top: false,
              child: Container(
                color: Colors.black.withOpacity(0.65),
                padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isLoading)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!_isLoading && statusIcon != null) ...[
                          Icon(statusIcon, color: _statusColor, size: 32),
                          const SizedBox(width: 8),
                        ],
                        Flexible(
                          child: Text(
                            _statusLabel,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _statusColor,
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_confidence > 0 && !_hasError)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '${_strings.confidenceLabel}: ${(_confidence * 100).toStringAsFixed(1)}%',
                          style: const TextStyle(color: Colors.white70, fontSize: 14),
                        ),
                      ),
                    if (_hasError)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: SizedBox(
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
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              minimumSize: const Size.fromHeight(52),
                              backgroundColor: _colorAccent,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
