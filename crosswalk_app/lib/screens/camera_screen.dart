import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/classifier.dart';
import '../services/feedback_service.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  final Classifier _classifier = Classifier();
  final FeedbackService _feedback = FeedbackService();

  String _statusLabel = '초기화 중...';
  double _confidence = 0.0;
  bool _isProcessing = false;
  bool _hasError = false;

  static const _labelColors = {
    'front': Colors.green,
    'left':  Colors.red,
    'right': Colors.orange,
  };

  static const _labelText = {
    'front': '정상 진행',
    'left':  '왼쪽 이탈',
    'right': '오른쪽 이탈',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _initCamera();
  }

  Future<void> _initCamera() async {
    setState(() {
      _hasError = false;
      _statusLabel = '초기화 중...';
    });

    try {
      // TTS를 먼저 초기화해야 이후 오류 발생 시 음성 안내 가능
      await _feedback.init();

      final status = await Permission.camera.request();
      if (!status.isGranted) {
        await _feedback.announceError('카메라 권한이 필요합니다. 설정에서 허용해주세요.');
        if (mounted) {
          setState(() {
            _hasError = true;
            _statusLabel = '카메라 권한 필요';
          });
        }
        return;
      }

      setState(() => _statusLabel = '모델 로딩 중...');
      await _classifier.init();

      setState(() => _statusLabel = '카메라 연결 중...');
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        await _feedback.announceError('카메라를 찾을 수 없습니다.');
        if (mounted) {
          setState(() {
            _hasError = true;
            _statusLabel = '카메라 없음';
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
      setState(() => _statusLabel = '감지 중...');
    } on ModelIntegrityException {
      await _feedback.announceError(
        '모델 파일이 손상되었습니다. 앱을 다시 설치해주세요.',
      );
      if (mounted) {
        setState(() {
          _hasError = true;
          _statusLabel = '오류: 모델 손상';
        });
      }
    } catch (e) {
      await _feedback.announceError(
        '앱 오류로 감지를 시작할 수 없습니다. 앱을 다시 시작해주세요.',
      );
      if (mounted) {
        setState(() {
          _hasError = true;
          _statusLabel = '오류: 감지 불가';
        });
      }
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
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _controller!.dispose();
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
    _feedback.dispose();
    super.dispose();
  }

  Color get _statusColor {
    if (_hasError) return Colors.red;
    if (_statusLabel == '정상 진행') return Colors.green;
    if (_statusLabel == '왼쪽 이탈') return Colors.red;
    if (_statusLabel == '오른쪽 이탈') return Colors.orange;
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
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

          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              color: Colors.black.withOpacity(0.65),
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _statusLabel,
                    style: TextStyle(
                      color: _statusColor,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (_confidence > 0 && !_hasError)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '신뢰도: ${(_confidence * 100).toStringAsFixed(1)}%',
                        style: const TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                    ),
                  if (_hasError)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: TextButton(
                        onPressed: _initCamera,
                        child: const Text(
                          '다시 시도',
                          style: TextStyle(color: Colors.white, fontSize: 16),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
