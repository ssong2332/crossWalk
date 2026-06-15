import 'package:flutter/material.dart';
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
    try {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        setState(() => _statusLabel = '카메라 권한이 필요합니다');
        return;
      }

      setState(() => _statusLabel = '모델 로딩 중...');
      await _classifier.init();

      setState(() => _statusLabel = '카메라 연결 중...');
      await _feedback.init();

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _statusLabel = '카메라를 찾을 수 없습니다');
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
    } catch (e) {
      if (mounted) {
        setState(() => _statusLabel = '오류: $e');
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

  Color get _statusColor => _labelColors[
    _statusLabel == '정상 진행' ? 'front' :
    _statusLabel == '왼쪽 이탈' ? 'left' :
    _statusLabel == '오른쪽 이탈' ? 'right' : 'front'
  ] ?? Colors.grey;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 카메라 프리뷰
          if (_controller != null && _controller!.value.isInitialized)
            Positioned.fill(
              child: CameraPreview(_controller!),
            ),

          // 상태 오버레이 (하단)
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
                  if (_confidence > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '신뢰도: ${(_confidence * 100).toStringAsFixed(1)}%',
                        style: const TextStyle(color: Colors.white70, fontSize: 14),
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
