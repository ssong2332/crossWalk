import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:image/image.dart' as img;

class ClassificationResult {
  final String label;
  final double confidence;
  const ClassificationResult(this.label, this.confidence);
}

class Classifier {
  static const _labels = ['front', 'left', 'right'];
  static const _inputSize = 224;
  static const _smoothingWindow = 5;
  static const _confidenceThreshold = 0.70;
  static const _throttleFrames = 10;

  OrtSession? _session;
  int _frameCount = 0;
  final List<List<double>> _recentProbs = [];

  Future<void> init() async {
    OrtEnv.instance.init();
    final sessionOptions = OrtSessionOptions();
    _session = await OrtSession.fromAsset(
      'assets/model/crosswalk_model.onnx',
      sessionOptions,
    );
  }

  ClassificationResult? processFrame(CameraImage cameraImage) {
    _frameCount++;
    if (_frameCount % _throttleFrames != 0) return null;

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
    final probs = (rawOutput.first as List).map((e) => (e as double)).toList();
    outputTensor.release();

    _recentProbs.add(probs);
    if (_recentProbs.length > _smoothingWindow) {
      _recentProbs.removeAt(0);
    }

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

    if (avgProbs[bestIdx] < _confidenceThreshold) return null;
    return ClassificationResult(_labels[bestIdx], avgProbs[bestIdx]);
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
    OrtEnv.instance.release();
  }
}
