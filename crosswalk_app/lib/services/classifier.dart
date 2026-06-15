import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
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

  Interpreter? _interpreter;
  int _frameCount = 0;
  final List<List<double>> _recentProbs = [];

  Future<void> init() async {
    _interpreter = await Interpreter.fromAsset('assets/model/crosswalk_model.tflite');
  }

  // 10프레임마다 1회 추론, 5회 평균 스무딩
  ClassificationResult? processFrame(CameraImage cameraImage) {
    _frameCount++;
    if (_frameCount % _throttleFrames != 0) return null;

    final input = _preprocessCamera(cameraImage);
    if (input == null) return null;

    final output = List.filled(1 * _labels.length, 0.0).reshape([1, _labels.length]);
    _interpreter!.run(input, output);

    final probs = List<double>.from(output[0] as List);
    _recentProbs.add(probs);
    if (_recentProbs.length > _smoothingWindow) {
      _recentProbs.removeAt(0);
    }

    // 최근 N회 평균
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

  List<List<List<List<double>>>>? _preprocessCamera(CameraImage image) {
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

      // ImageNet 정규화
      const mean = [0.485, 0.456, 0.406];
      const std = [0.229, 0.224, 0.225];

      return List.generate(1, (_) =>
        List.generate(_inputSize, (y) =>
          List.generate(_inputSize, (x) {
            final pixel = resized.getPixel(x, y);
            return [
              (pixel.r / 255.0 - mean[0]) / std[0],
              (pixel.g / 255.0 - mean[1]) / std[1],
              (pixel.b / 255.0 - mean[2]) / std[2],
            ];
          })
        )
      );
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
    _interpreter?.close();
  }
}
