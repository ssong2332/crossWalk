import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/classifier.dart';
import '../services/feedback_service.dart';
import '../services/angle_estimator.dart';
import '../services/stripe_direction_estimator.dart';
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
  // T70: 학습된 각도 회귀 모델. 분류기와 별도 세션이며, 횡단보도가
  // 보이는 상태에서만 돌린다(none이면 각도라는 개념 자체가 없다).
  final AngleEstimator _angleEstimator = AngleEstimator();

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

  // T65: 배터리 절약 모드. 켜면 화살표만 그리는 계기판만 표시하고, 끄면(기본값)
  // 카메라 프리뷰가 배경에 함께 보인다. 사용자 명시 요청(2026-08-24)으로
  // 기본값을 false로 변경 — 배터리 절약보다 "지금 보이는 화면"을 기본으로
  // 우선한다. 세션 한정 — 재시작 시 이 기본값(false)으로 돌아간다.
  bool _powerSaveMode = false;

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
  static const _colorLeft = _colorAmber;
  // T63: 심한 이탈 전용 색. amber와 상호 대비가 1.6:1로 낮아 색만으로는
  // 약/심 구분이 확실하지 않다 — 그래서 색 하나에 기대지 않는다. 텍스트
  // 라벨(labelLeftSevere/labelRightSevere)·굵은 화살표·넓은 가장자리
  // 펄스로 겹쳐 전달한다. 배경(#0E1013) 대비 6.24:1로 AA를 만족한다.
  static const _colorSevere = Color(0xFFFF5A5F);

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

  Map<String, String> get _labelText => {
        'front': _strings.labelFront,
        'left': _strings.labelLeft,
        'right': _strings.labelRight,
        'none': _strings.labelNone,
        'approach': _strings.labelApproach,
      };

  // 마지막으로 받은 분류 라벨. `_fieldState`가 오류/로딩/무판정이 아닐 때
  // 이 값을 그대로 쓴다.
  String _guidanceLabel = 'front';

  // T63: 좌/우 가장자리 펄스 애니메이션. left/right 상태일 때만 반복
  // 재생하고, 그 외에는 멈춘다 (동기화는 build()의 _syncPulseAnimation에서).
  // T41의 코리도 애니메이션 컨트롤러를 재사용한다 — Claude Design 시안
  // 반영(PR #74)으로 GuidanceCorridorPainter가 사라진 뒤에도 이 컨트롤러와
  // 연결된 커브/색 트윈은 아무도 읽지 않는 채로 남아 있었다(매 프레임
  // _updateGuidanceTarget이 갱신만 하고 결과를 아무도 소비하지 않는 죽은
  // 되먹임). 그 죽은 로직을 걷어내고 실제로 쓰이는 펄스 애니메이션으로
  // 대체했다.
  late final AnimationController _pulseController;

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
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _initCamera();
  }

  Future<void> _initCamera() async {
    if (_isInitializing) return;
    _isInitializing = true;

    try {
      // T67: 카메라가 새로 뜨면 이전 세션의 각도는 더 이상 유효하지 않다
      // (앱 재개 등으로 전혀 다른 장면일 수 있다). 스무딩 상태를 비워
      // 낡은 각도로 화살표가 잘못 돌아가는 것을 막는다.
      _angleSmoother.reset();

      setState(() {
        _hasError = false;
        _permissionPermanentlyDenied = false;
        _torchEnabled = false;
        _statusLabel = _strings.initializing;
        _arrowStripeAngle = null;
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
        // 각도 모델 초기화 실패는 치명적이지 않다 — 각도만 못 쓰고
        // 화살표는 기존 좌/우 표시로 동작한다. 앱 전체를 막지 않는다.
        try {
          await _angleEstimator.init();
        } catch (e) {
          debugPrint('[T70] 각도 모델 초기화 실패(각도 없이 계속 진행): $e');
        }

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
  // T63: 배터리 절약 모드 전환 — 플러그인 호출이 없으므로 동기 setState뿐이다.
  // T64(사용자 스크린샷 지적, 2026-08-24): `CameraPreview`는 내부에서
  // `AspectRatio(aspectRatio: 1/controller.value.aspectRatio, ...)`로
  // 감싸여 있다(camera 0.11.2 lib/src/camera_preview.dart). `Positioned.fill`이
  // 주는 타이트한 제약 안에서도 AspectRatio는 스트레치가 아니라 "그 안에 들어가는
  // 가장 큰 사각형"을 고른다 — 화면 비율과 카메라 센서 비율이 다르면 레터/필러박스
  // 여백이 생긴다. 스크림(0.86 불투명도)이 그 위를 덮긴 하지만, 카메라 화소가
  // 실제로 있는 영역만 14%가 비쳐 보이고 여백은 배경색과 거의 같은 색이라 —
  // 사각형 경계가 도드라져 보였다("너무 형식적으로 끊겨 있다").
  //
  // 화면을 항상 꽉 채우도록(BoxFit.cover와 동일한 효과) 이미 아스펙트비로
  // 맞춰진 CameraPreview를 균일하게 확대한다. 유도:
  //   camAspect = 1 / controller.aspectRatio  (CameraPreview가 세로 모드에서
  //     실제로 쓰는 값 — 이 앱은 portraitUp으로 고정돼 있어 가로 분기는 타지 않는다)
  //   boxAspect = 박스 너비 / 높이
  //   camAspect >= boxAspect  -> 상하 레터박스 생김 -> scale = camAspect/boxAspect
  //   camAspect <  boxAspect  -> 좌우 필러박스 생김 -> scale = boxAspect/camAspect
  // 실기기로 시각 확인은 못 했다(이 환경엔 카메라 기기가 없다) — 계산 유도만
  // 검증했고, 실기기에서 잘림·확대가 과하지 않은지 확인이 필요하다.
  Widget _buildFullBleedPreview() {
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return CameraPreview(controller);
        }
        final camAspect = 1 / controller.value.aspectRatio;
        final boxAspect = constraints.maxWidth / constraints.maxHeight;
        final scale = camAspect >= boxAspect
            ? camAspect / boxAspect
            : boxAspect / camAspect;
        return ClipRect(
          child: Transform.scale(
            scale: scale,
            child: Center(child: CameraPreview(controller)),
          ),
        );
      },
    );
  }

  void _setPowerSaveMode(bool enabled) {
    if (mounted) setState(() => _powerSaveMode = enabled);
  }

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
      _feedback.alert(result.label, result.confidence);
      if (mounted) {
        setState(() {
          _statusLabel = _labelText[result.label] ?? result.label;
          _confidence = result.confidence;
          _lastResultAt = DateTime.now();
          _noCall = false;
        });
        _guidanceLabel = result.label;
      }
    }

    _updateAngleEstimate(image);

    _isProcessing = false;
  }

  // T70: 화살표가 따라갈 각도. **학습된 회귀 모델**(`AngleEstimator`)이 낸다.
  //
  // T66~T67에서 쓰던 고전 CV(`StripeDirectionEstimator`)를 대체했다 —
  // 사람 라벨 405장 기준 실측에서 고전 CV는 평균 오차 34.5도로 학습 없는
  // "항상 0도"(32.4도)보다도 나빴고, 학습 모델은 13.4도로 61% 줄였다
  // (docs/Tasks.md T67-2 / T69).
  int _angleFrameCount = 0;
  double? _lastRawAngle;

  // raw 추정치를 그대로 쓰면 화살표가 떨리고 한 프레임 실패에도 깜빡이므로
  // 스무딩·히스테리시스를 거친다(T67에서 만든 것을 그대로 재사용).
  // 회귀 모델은 신뢰도를 내지 않으므로 신뢰도 게이트는 쓰지 않는다 —
  // 대신 "횡단보도가 보이는 상태인지"를 분류기 결과로 판단한다(아래).
  final StripeAngleSmoother _angleSmoother =
      StripeAngleSmoother(minConfidence: 0.0, smoothingFactor: 0.6);
  double? _arrowStripeAngle;

  void _updateAngleEstimate(CameraImage image) {
    if (!_angleEstimator.isReady) return;

    _angleFrameCount++;
    // 10프레임마다 1회(약 3Hz). **분류기와 겹치지 않게 3번째 프레임에 건다** —
    // `Classifier`의 스로틀은 5프레임 주기(5,10,15...)라 0으로 두면 매번 같은
    // 프레임에서 두 모델이 연달아 돌아 프레임 콜백이 길게 막힌다.
    if (_angleFrameCount % 10 != 3) return;

    // 횡단보도가 안 보이는 상태(none)에서는 각도라는 개념 자체가 없다.
    // 모델은 그래도 숫자를 내지만 그건 의미 없는 값이므로 받지 않는다.
    final hasCrosswalk = _guidanceLabel == 'front' ||
        _guidanceLabel == 'left' ||
        _guidanceLabel == 'right' ||
        _guidanceLabel == 'approach';

    double? raw;
    if (hasCrosswalk && !_noCall) {
      // 학습 라벨이 EXIF 보정된 화면(세로) 방향 기준이라, 센서 버퍼를 그대로
      // 넣으면 약 90도 계통 오차가 난다. sensorOrientation만큼 시계방향
      // 회전을 적용해 맞춘다(angle_estimator.dart의 sensorCoord).
      final rot = _controller?.description.sensorOrientation ?? 90;
      raw = _angleEstimator.estimate(image, rot);
    }

    if (kDebugMode) {
      debugPrint('[T70 angle] label=$_guidanceLabel raw=$raw');
    }

    final smoothed = _angleSmoother.add(
      raw == null ? null : StripeDirectionEstimate(raw, 1.0),
    );

    if (mounted) {
      setState(() {
        _lastRawAngle = raw;
        _arrowStripeAngle = smoothed;
      });
    }
  }

  /// T67: 상태 필드(화살표). 각도를 아는 동안에는 화살표가 감지된 횡단보도
  /// 방향을 따라 **부드럽게 회전**한다.
  ///
  /// 회전을 `TweenAnimationBuilder`로 보간하는 이유: 각도 추정은 10프레임마다
  /// 한 번(약 3Hz)만 갱신되므로, 값을 그대로 그리면 화살표가 뚝뚝 끊겨
  /// 움직인다. 목표 각도까지 애니메이션으로 이어 그려야 "횡단보도와 실시간
  /// 동기화"처럼 보인다.
  ///
  /// 접근성: `MediaQuery.disableAnimations`(모션 감소)가 켜져 있으면 보간을
  /// 끄고 즉시 목표 각도로 그린다 — 화살표가 가리키는 정보 자체는 그대로
  /// 유지되고 움직임만 사라진다.
  Widget _buildStateField(Color color, bool reducedMotion) {
    final angle = _arrowStripeAngle;

    if (angle == null) {
      // 각도 무판정 — 기존 고정 화살표로 되돌아간다.
      return CustomPaint(
        size: Size.infinite,
        painter: StateFieldPainter(
          state: _fieldState,
          color: color,
          severe: _severe,
        ),
      );
    }

    if (reducedMotion) {
      return CustomPaint(
        size: Size.infinite,
        painter: StateFieldPainter(
          state: _fieldState,
          color: color,
          severe: _severe,
          stripeAngleDegrees: angle,
        ),
      );
    }

    return TweenAnimationBuilder<double>(
      // `end`만 준다 — TweenAnimationBuilder는 end가 바뀔 때마다 **현재
      // 그려지고 있는 값**에서 새 end까지 이어서 보간한다. begin을 함께
      // 주면 매번 그 값에서 다시 시작해버려 오히려 튄다.
      tween: Tween<double>(end: angle),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      builder: (context, animatedAngle, _) => CustomPaint(
        size: Size.infinite,
        painter: StateFieldPainter(
          state: _fieldState,
          color: color,
          severe: _severe,
          stripeAngleDegrees: animatedAngle,
        ),
      ),
    );
  }

  /// T70: 실기기 검증용 표시. 모델이 낸 값을 그대로 보여준다 —
  /// 화살표가 실제로 움직이는지, 그리고 **회전 보정이 맞는지**
  /// (틀리면 약 90도 계통 오차가 난다)를 사람이 바로 확인할 수 있게 한다.
  ///
  /// T75(2026-09-04): 문구를 "각도"에서 **"보정"** 으로 바꿨다. 이 값은
  /// 횡단보도가 실제로 몇 도 기울었는지를 재는 **측정값이 아니다** —
  /// 라벨링 시 횡단보도 내 좌우 위치에 따른 위험 가중이 더해져 있어
  /// (실측: 위치 한 단계당 +7.3도), 가장자리에서 바깥으로 향할수록 값이
  /// 실제 기하 각도보다 크게 나온다. "각도"라고 쓰면 사용자가 이를 실제
  /// 방향으로 읽어 오도된다. 자세한 근거는 docs/Tasks.md T74.
  String _stripeDebugText() {
    if (!_angleEstimator.isReady) return '보정 모델 준비 중';
    final raw = _lastRawAngle;
    if (raw == null) return '보정: 횡단보도 미검출';
    final shown = _arrowStripeAngle ?? raw;
    return '보정 ${shown.toStringAsFixed(0)} (원시 ${raw.toStringAsFixed(0)})';
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
    _pulseController.dispose();
    _controller?.dispose();
    _classifier.dispose();
    _angleEstimator.dispose();
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
  // Claude Design 1a: 화면이 Stack에서 Column(계기판)으로 바뀌면서
  // `Positioned.fill`을 쓸 수 없게 됐다 — Positioned는 Stack 자식일 때만
  // 유효하고, Column 안에서는 ParentData 타입 불일치로 즉시 assert가 터진다.
  // 오류 카드는 이제 Column의 Expanded 자식으로 화면을 채운다.
  Widget _buildErrorCard() {
    return SizedBox.expand(
      child: ColoredBox(
        color: _colorBg,
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
            const Icon(Icons.warning_rounded,
                color: Color(0xFF3A2C00), size: 20),
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
                  powerSaveMode: _powerSaveMode,
                  onPowerSaveModeChanged: _setPowerSaveMode,
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

  // T63: 이 분류기는 좌표·기하 정보를 내지 않으므로 "얼마나 벗어났는지"를
  // 직접 재지 못한다. left/right 확신도를 이탈 정도의 **근사치**로 쓴다
  // (Classifier.deviationSeverityThreshold 문서 참조, 잠정값).
  bool get _severe =>
      (_guidanceLabel == 'left' || _guidanceLabel == 'right') &&
      _confidence >= Classifier.deviationSeverityThreshold;

  Color get _fieldColor {
    switch (_fieldState) {
      case 'left':
      case 'right':
        return _severe ? _colorSevere : _colorAmber;
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
      // T63: 심한 이탈은 별도 라벨을 쓴다 — 색만으로 강도를 구분하지 않기
      // 위한 텍스트 겹침. 화면은 관측형 문장을 유지한다(1g).
      case 'left':
        return _severe ? _strings.labelLeftSevere : _strings.labelLeft;
      case 'right':
        return _severe ? _strings.labelRightSevere : _strings.labelRight;
      default:
        return _labelText[_fieldState] ?? _statusLabel;
    }
  }

  /// 보조 한 줄 — 화살표와 같은 편, 즉 **가야 할 방향**.
  String get _fieldSubline {
    if (_fieldState == 'nocall') return _strings.noCallBody;
    return _strings.cameraStateDescriptions[_fieldState] ?? '';
  }

  // T63: 화살표는 이제 "가야 할 방향"이 아니라 **현재 이탈 방향**을 가리킨다
  // (사용자 확정, 2026-08-24) — 왼쪽으로 틀어졌으면 화살표가 왼쪽을 가리킨다.
  // "가야 할 방향"은 대신 반대편 가장자리의 펄스로 전달한다: state가
  // 'left'면 목표는 오른쪽이므로 오른쪽 가장자리가 맥동한다.
  String? get _pulseEdge {
    if (_fieldState == 'left') return 'right';
    if (_fieldState == 'right') return 'left';
    return null;
  }

  /// 펄스 컨트롤러를 현재 상태에 맞춰 켜고 끈다. build()마다 호출해도
  /// 안전하다 — isAnimating을 먼저 확인해 중복 repeat()/stop() 호출을 막는다.
  void _syncPulseAnimation(bool reducedMotion) {
    final active = _pulseEdge != null && !reducedMotion;
    if (active && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (!active && _pulseController.isAnimating) {
      _pulseController.stop();
    }
  }

  /// 목표 방향 가장자리 펄스 — 화면 전체 높이를 쓰는 은은한 번짐(ambient
  /// glow)이다. 접근성: `MediaQuery.disableAnimations`가 켜져 있으면(모션 감소
  /// 설정) 애니메이션 대신 고정 밝기로 표시한다.
  ///
  /// T64(사용자 지적, 2026-08-24 — "펄스가 전체적으로 보이도록, 지금은 너무
  /// 형식적으로 끊겨 있어"): 초판은 상태 필드 영역(위·아래 여백 제외)에만
  /// 갇힌 56~88px 고정폭 막대였다 — 화면 일부에만 걸쳐 있어 잘린 사각형처럼
  /// 보였다. 이제 화면 전체 높이(SafeArea 밖, 최상위 Stack)에 걸쳐 그리고,
  /// 폭도 화면 너비의 비율로 잡아(약함 32% / 심함 48%) 화면 크기가 달라져도
  /// 비례한다. 3단 그라디언트(가장자리->중간->투명)로 경계를 더 부드럽게
  /// 풀었다 — 2단 그라디언트는 중간 지점에서 밝기가 급격히 꺾여 보인다.
  Widget _buildEdgePulse(Color color, bool reducedMotion) {
    final edge = _pulseEdge;
    if (edge == null) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth * (_severe ? 0.48 : 0.32);
        final peakAlpha = _severe ? 0.42 : 0.26;
        final alignment =
            edge == 'right' ? Alignment.centerRight : Alignment.centerLeft;
        final gradientBegin = alignment;
        final gradientEnd =
            edge == 'right' ? Alignment.centerLeft : Alignment.centerRight;

        Widget bar(double alpha) => Align(
              alignment: alignment,
              child: IgnorePointer(
                child: Container(
                  width: width,
                  height: double.infinity,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: gradientBegin,
                      end: gradientEnd,
                      stops: const [0.0, 0.55, 1.0],
                      colors: [
                        color.withValues(alpha: alpha),
                        color.withValues(alpha: alpha * 0.35),
                        color.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            );

        if (reducedMotion) return bar(peakAlpha * 0.7);

        return AnimatedBuilder(
          animation: _pulseController,
          builder: (context, _) {
            final t = Curves.easeInOut.transform(_pulseController.value);
            return bar(peakAlpha * 0.35 + peakAlpha * 0.65 * t);
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Claude Design 1l: 200%에서 살아남는 방법은 크기를 줄이는 것이 아니라
    // **내용을 버리는 것**이다. 확대 시 확신도 같은 2차 정보는 화면에서 빠지고
    // 음성으로만 남는다. 어떤 컨테이너에도 고정 높이를 주지 않는다.
    final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
    final dense = scale > 1.5;
    final color = _fieldColor;
    final reducedMotion = MediaQuery.of(context).disableAnimations;
    _syncPulseAnimation(reducedMotion);

    // T63/T65: 배터리 절약 모드가 꺼져 있으면(T65부터 기본값) 카메라 프리뷰를
    // 배경에 보여준다. Claude Design 1a가 프리뷰를 없앤 이유(배경이 매 프레임
    // 바뀌어 전경 텍스트의 대비를 보장할 수 없음)는 여전히 유효하다.
    //
    // T65(사용자 명시 요청, 2026-08-24 "화면이 너무 어두워"): 이전에는
    // 화면 전체에 0.86 스크림을 깔아 텍스트 대비를 보장했는데, 그 결과 상태
    // 필드(화살표) 영역까지 함께 어두워져 프리뷰가 거의 안 보였다. 지금은
    // 텍스트가 실제로 놓이는 상단 칩/하단 판독부에만 각자 불투명 배경을 주고
    // (상단 칩·경고 배너는 이미 자체 배경 보유), 화면 전체 스크림은 없앴다 —
    // 상태 필드는 카메라 원본 밝기 그대로 보인다.
    final showPreview = !_powerSaveMode &&
        _controller != null &&
        _controller!.value.isInitialized;

    return Scaffold(
      backgroundColor: _colorBg,
      body: Stack(
        children: [
          if (showPreview) Positioned.fill(child: _buildFullBleedPreview()),
          // T64: 펄스를 화면 전체 높이로 옮겼다 — 상태 필드 영역에만 갇혀
          // 있던 초판은 화면 일부에서만 번져 잘린 사각형처럼 보였다.
          Positioned.fill(child: _buildEdgePulse(color, reducedMotion)),
          SafeArea(
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
                if (!_hasError)
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
                              child: _buildStateField(color, reducedMotion),
                            ),
                    ),
                  ),

                // ── 하단 판독부 ──────────────────────────────────────────────
                // 오류 상태에서는 전용 오류 카드가 화면 전체를 채우므로 그리지 않는다.
                //
                // T65: 이 블록만 자체 배경(0.86)을 가진다 — 화면 전체 스크림을
                // 없앤 대신, 실제 텍스트가 놓이는 이 영역에만 이전과 동일한
                // 수학적 보장(계산: 텍스트 #F1F3F4(휘도 0.92) vs 스크림 후
                // 최악 휘도(순백 프레임 가정) (1-0.86)*1.0 + 0.86*L(#0E1013)
                // ≈ 0.15 -> 대비 4.85:1, AA 4.5:1 충족)을 남긴다.
                if (!_hasError)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: showPreview
                            ? _colorBg.withValues(alpha: 0.86)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                      ),
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
                        // T66: 실험적 프로토타입 표시 — 화살표·안내와 무관.
                        // 컴퓨터 연결 없이 release APK를 폰에 설치해도 바로
                        // 볼 수 있게 화면에 직접 낸다(2026-08-24 요청). 정식
                        // 기능처럼 보이지 않도록 점선 테두리 + "실험적" 라벨로
                        // 구분한다.
                        if (!dense && !_hasError)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: _colorTextDim.withValues(alpha: 0.4),
                                  width: 1,
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
                                child: Text(
                                  _stripeDebugText(),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: _colorTextDim.withValues(alpha: 0.8),
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.only(top: 14),
                          child: Text(
                            _strings.cameraGuidanceDisclaimer,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: _colorTextDim,
                                fontSize: 13,
                                height: 1.4),
                          ),
                        ),
                      ],
                      ),
                    ),
                  ),

                if (_hasError) Expanded(child: _buildErrorCard()),
              ],
            ),
          ),
        ],
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
  const StateFieldPainter({
    required this.state,
    required this.color,
    this.severe = false,
    this.stripeAngleDegrees,
  });

  /// 'front' | 'left' | 'right' | 'approach' | 'none' | 'nocall' | 'error'
  final String state;
  final Color color;

  /// T63: 심한 이탈일 때 굵고 큰 화살표를 그린다 — 색만으로 강도를 구분하지
  /// 않기 위한 비-색 겹침(redundancy). left/right가 아니면 무시된다.
  final bool severe;

  /// T67: 실시간으로 추정한 횡단보도 줄무늬 기울기(도, 수평 기준).
  ///
  /// 값이 있으면 화살표가 **실제 감지된 횡단보도가 뻗은 방향**(진행 방향)을
  /// 가리키도록 회전한다. null이면(무판정·저신뢰) 회전하지 않고 기존의 고정
  /// 화살표로 되돌아간다 — 모르는 각도를 지어내지 않는다.
  ///
  /// 기하: 줄무늬는 진행 방향과 **수직**이다. 줄무늬 선의 방향이
  /// (cos θ, sin θ)이므로 진행 방향은 (sin θ, −cos θ)이고, 캔버스 회전각은
  /// atan2(−cos θ, sin θ) = θ − π/2 가 된다. θ=0(줄무늬가 화면에서 수평)일 때
  /// −π/2(위쪽) — 기존 'front' 화살표와 정확히 일치한다.
  final double? stripeAngleDegrees;

  static const _pi = 3.1415926535897932;

  /// 화살표가 실제로 회전 가능한 상태인지 — left/right/front에서만,
  /// 그리고 각도를 알 때만.
  bool get _tracksStripe =>
      stripeAngleDegrees != null &&
      (state == 'front' || state == 'left' || state == 'right');

  /// 추정 각도를 캔버스 회전각(라디안)으로 바꾼다.
  double get _stripeRotation => stripeAngleDegrees! * _pi / 180 - _pi / 2;

  /// 캔버스에 실제로 그려진 픽셀을 검사하기는 어려우므로, 회전 조건과
  /// 회전각 계산을 테스트에서 직접 확인할 수 있게 노출한다.
  @visibleForTesting
  bool get tracksStripeForTest => _tracksStripe;

  @visibleForTesting
  double get stripeRotationForTest => _stripeRotation;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = (state == 'left' || state == 'right') && severe ? 14 : 10
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    final baseUnit = size.shortestSide * 0.30;
    final unit = (state == 'left' || state == 'right') && severe
        ? baseUnit * 1.2
        : baseUnit;
    // T67: 각도를 알면 세 상태 모두 화살표가 **감지된 횡단보도가 뻗은
    // 방향**을 가리킨다(실시간 동기화).
    //
    // T72(2026-09-04, 사용자 지시): 화살표를 **세 상태 모두 화면 중앙**에
    // 고정하고 방향(회전)만 바꾼다. 이전에는 이탈 방향으로 위치를 옮겼으나
    // (좌 0.30 / 우 0.70), 사용자가 위치 이동 없이 방향만 바뀌기를 요청했다.
    // 위치라는 채널 하나가 빠지는 대신, 이탈 정보는 색·문구·가장자리
    // 펄스(`CameraScreen._buildEdgePulse`)·음성·진동이 계속 전달하므로
    // 색각이상에서도 중복 채널은 유지된다.
    final center = Offset(size.width / 2, size.height / 2);
    switch (state) {
      case 'front':
        _arrow(canvas, stroke, center, unit,
            _tracksStripe ? _stripeRotation : -_pi / 2);
        break;
      // T63(2026-08-24, 사용자 확정): 각도를 모를 때의 화살표는 **가야 할
      // 방향**이 아니라 **현재 이탈 방향**을 가리킨다. 목표 방향은 반대편
      // 가장자리 펄스로 전달한다(CameraScreen._buildEdgePulse).
      case 'left':
        _arrow(canvas, stroke, center, unit,
            _tracksStripe ? _stripeRotation : _pi);
        break;
      case 'right':
        _arrow(canvas, stroke, center, unit,
            _tracksStripe ? _stripeRotation : 0);
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
    return oldDelegate.state != state ||
        oldDelegate.color != color ||
        oldDelegate.severe != severe ||
        oldDelegate.stripeAngleDegrees != stripeAngleDegrees;
  }
}
