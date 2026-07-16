import 'dart:math' as math;
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:meta/meta.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:image/image.dart' as img;

class ClassificationResult {
  final String label;
  final double confidence;
  const ClassificationResult(this.label, this.confidence);
}

class ModelIntegrityException implements Exception {
  final String message;
  const ModelIntegrityException(this.message);
  @override
  String toString() => message;
}

class Classifier {
  static const _labels = ['front', 'left', 'right'];
  static const _inputSize = 224;
  static const _smoothingWindow = 5;

  // 이탈(left/right)은 민감하게, 정상(front) 확인은 엄격하게
  static const _deviationThreshold = 0.55;
  static const _frontThreshold = 0.85;

  // 10 → 5: 약 6fps@30fps, 이탈 감지 지연 단축
  static const _throttleFrames = 5;

  OrtSession? _session;
  int _frameCount = 0;
  final List<List<double>> _recentProbs = [];

  // OrtEnv.instance.init()은 호출할 때마다 네이티브 OrtEnv를 새로 생성하며
  // 이전 포인터를 해제하지 않으므로(onnxruntime 1.4.1, lib/src/ort_env.dart),
  // 최초 1회만 초기화하고 dispose() 시 release() 후 다시 false로 되돌린다.
  bool _envInitialized = false;

  Future<void> init() async {
    // 동일 인스턴스에 대해 init()이 재호출되는 경우(앱 재개, 재시도 등)
    // 이전 세션을 해제하지 않으면 네이티브 OrtSession이 누수된다.
    _session?.release();
    _session = null;

    if (!_envInitialized) {
      OrtEnv.instance.init();
      _envInitialized = true;
    }

    final rawAsset = await rootBundle.load('assets/model/crosswalk_model.onnx');
    final bytes = rawAsset.buffer.asUint8List();
    await _verifyModelIntegrity(bytes);
    _session = OrtSession.fromBuffer(bytes, OrtSessionOptions());
  }

  Future<void> _verifyModelIntegrity(Uint8List modelBytes) async {
    try {
      final hashFile = await rootBundle.loadString(
        'assets/model/crosswalk_model.onnx.sha256',
      );
      final expectedHash = hashFile.trim();

      // placeholder 해시이거나 형식이 다르면 검증 건너뜀 (더미 빌드 / 개발 환경)
      if (expectedHash.length != 64 || expectedHash == 'placeholder_hash') return;

      final actualHash = sha256.convert(modelBytes).toString();
      if (actualHash != expectedHash) {
        throw ModelIntegrityException(
          '모델 파일이 손상되었거나 변조되었습니다. 앱을 다시 설치해주세요.',
        );
      }
    } catch (e) {
      if (e is ModelIntegrityException) rethrow;
      // 해시 파일 없음 → 개발 환경, 건너뜀
    }
  }

  ClassificationResult? processFrame(CameraImage cameraImage) {
    if (!shouldProcessFrame()) return null;

    final input = _preprocessCamera(cameraImage);
    if (input == null) return null;

    final inputTensor = OrtValueTensor.createTensorWithDataList(
      input,
      [1, 3, _inputSize, _inputSize],
    );
    final runOptions = OrtRunOptions();
    final outputs = _session!.run(runOptions, {'input': inputTensor});
    inputTensor.release();
    runOptions.release();

    if (outputs == null || outputs.isEmpty) return null;

    final outputTensor = outputs.first as OrtValueTensor;
    final rawOutput = outputTensor.value as List;
    final logits = (rawOutput.first as List).map((e) => (e as double)).toList();
    outputTensor.release();

    return decideFromLogits(logits);
  }

  /// 프레임 카운터를 증가시키고, 이번 프레임을 처리할 차례인지(스로틀 게이트 통과 여부) 반환한다.
  /// `processFrame`에서 분리되어 있어 ONNX 세션 없이도 스로틀 동작을 단위 테스트할 수 있다.
  @visibleForTesting
  bool shouldProcessFrame() {
    _frameCount++;
    return _frameCount % _throttleFrames == 0;
  }

  /// 로짓을 확률로 변환하고, 스무딩 평균 및 임계값 판정을 거쳐 최종 결과를 결정한다.
  /// `processFrame`에서 분리되어 있어 `OrtSession` 없이도 단위 테스트가 가능하다.
  @visibleForTesting
  ClassificationResult? decideFromLogits(List<double> logits) {
    final probs = softmax(logits);

    _recentProbs.add(probs);
    if (_recentProbs.length > _smoothingWindow) _recentProbs.removeAt(0);

    final avgProbs = List<double>.filled(_labels.length, 0.0);
    for (final p in _recentProbs) {
      for (int i = 0; i < _labels.length; i++) {
        avgProbs[i] += p[i] / _recentProbs.length;
      }
    }

    int bestIdx = 0;
    for (int i = 1; i < avgProbs.length; i++) {
      if (avgProbs[i] > avgProbs[bestIdx]) bestIdx = i;
    }

    final label = _labels[bestIdx];
    final conf = avgProbs[bestIdx];
    final threshold = label == 'front' ? _frontThreshold : _deviationThreshold;
    if (conf < threshold) return null;

    return ClassificationResult(label, conf);
  }

  Float32List? _preprocessCamera(CameraImage image) {
    try {
      img.Image? decoded;

      if (image.format.group == ImageFormatGroup.yuv420) {
        decoded = _convertYUV420(image);
      } else if (image.format.group == ImageFormatGroup.bgra8888) {
        decoded = img.Image.fromBytes(
          width: image.width,
          height: image.height,
          bytes: image.planes[0].bytes.buffer,
          order: img.ChannelOrder.bgra,
        );
      } else {
        return null;
      }

      final resized = img.copyResize(decoded, width: _inputSize, height: _inputSize);

      // NCHW 포맷 [1, 3, 224, 224] + ImageNet 정규화
      const mean = [0.485, 0.456, 0.406];
      const std = [0.229, 0.224, 0.225];

      final buffer = Float32List(3 * _inputSize * _inputSize);
      for (int y = 0; y < _inputSize; y++) {
        for (int x = 0; x < _inputSize; x++) {
          final pixel = resized.getPixel(x, y);
          final idx = y * _inputSize + x;
          buffer[0 * _inputSize * _inputSize + idx] = (pixel.r / 255.0 - mean[0]) / std[0];
          buffer[1 * _inputSize * _inputSize + idx] = (pixel.g / 255.0 - mean[1]) / std[1];
          buffer[2 * _inputSize * _inputSize + idx] = (pixel.b / 255.0 - mean[2]) / std[2];
        }
      }
      return buffer;
    } catch (_) {
      return null;
    }
  }

  /// 모델이 raw logits(softmax 미적용)를 출력하므로, 확률로 변환한다.
  /// (train/train_model.py는 CrossEntropyLoss로 학습되어 logits를 기대함)
  /// 오버플로 방지를 위해 최대 logit을 뺀 뒤 exponentiate하는
  /// 수치적으로 안정적인 softmax 구현.
  @visibleForTesting
  List<double> softmax(List<double> logits) {
    final maxLogit = logits.reduce((a, b) => a > b ? a : b);
    final exps = logits.map((l) => math.exp(l - maxLogit)).toList();
    final sumExps = exps.fold<double>(0.0, (a, b) => a + b);
    return exps.map((e) => e / sumExps).toList();
  }

  img.Image _convertYUV420(CameraImage image) {
    final w = image.width;
    final h = image.height;
    final out = img.Image(width: w, height: h);
    final yPlane = image.planes[0].bytes;
    final uPlane = image.planes[1].bytes;
    final vPlane = image.planes[2].bytes;
    final uvRowStride = image.planes[1].bytesPerRow;
    final uvPixelStride = image.planes[1].bytesPerPixel ?? 1;

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final yVal = yPlane[y * image.planes[0].bytesPerRow + x];
        final uvIdx = (y ~/ 2) * uvRowStride + (x ~/ 2) * uvPixelStride;
        final uVal = uPlane[uvIdx];
        final vVal = vPlane[uvIdx];
        final r = (yVal + 1.402 * (vVal - 128)).clamp(0, 255).toInt();
        final g = (yVal - 0.344136 * (uVal - 128) - 0.714136 * (vVal - 128)).clamp(0, 255).toInt();
        final b = (yVal + 1.772 * (uVal - 128)).clamp(0, 255).toInt();
        out.setPixelRgb(x, y, r, g, b);
      }
    }
    return out;
  }

  void dispose() {
    _session?.release();
    _session = null;
    OrtEnv.instance.release();
    _envInitialized = false;
  }
}
