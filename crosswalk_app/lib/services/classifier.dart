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
  // 5-클래스 모델(none/approach/front/left/right). 이 순서는 torchvision
  // ImageFolder가 하위 폴더명을 알파벳순으로 정렬해 만든 실제 모델 출력(logits)
  // 인덱스 순서와 정확히 일치해야 한다.
  //
  // T51: image/ 폴더가 `0_none`/`1_approach`/`2_front`/`3_left`/`4_right`로
  // 재구성되어, 알파벳순 정렬 결과가 곧 의미 순서가 된다. 실측값(ImageFolder의
  // class_to_idx 출력):
  //   {'0_none': 0, '1_approach': 1, '2_front': 2, '3_left': 3, '4_right': 4}
  // 즉 none=idx0, approach=idx1, front=idx2, left=idx3, right=idx4.
  // 이 순서를 "보기 편한" 순서로 바꾸면 로짓이 엉뚱한 라벨에 매핑되며
  // 에러 없이 조용히 오작동한다(T42에서 실제로 겪은 함정).
  // train/train_model.py가 학습 시작 시 class_to_idx를 assert로 검사한다.
  static const _labels = ['none', 'approach', 'front', 'left', 'right'];

  /// T54: 라벨 동기화 검증용 노출.
  /// `assets/model/labels.json`이 익스포트 시점의 모델과 함께 생성되며,
  /// `test/labels_sync_test.dart`가 이 배열과 그 파일을 대조한다.
  /// 이 프로젝트에서 라벨-모델 불일치는 세 번 발생했고 매번 에러 없이
  /// 조용히 틀린 라벨을 냈다(T42, T51, T51 브랜치의 4-class 에셋 잔류).
  @visibleForTesting
  static const labelsForTest = _labels;
  static const _inputSize = 224;
  static const _smoothingWindow = 5;

  // 이탈(left/right)은 민감하게, 정상(front) 확인은 엄격하게
  static const _deviationThreshold = 0.55;

  // T63: 이탈 "정도"를 판정하는 기준. 이 분류기는 좌표·기하 정보를 내지
  // 않으므로 실제 이탈 각도/거리는 알 수 없다 — left/right 확신도를
  // **근사치**로 쓴다. 확신도가 높을수록 그 방향으로의 특징이 뚜렷하다는
  // 것이지, 몇 도/몇 미터 벗어났는지를 재는 것이 아니다.
  // 0.80은 **잠정값**(측정 아님). _deviationThreshold(0.55)와 1.0 사이의
  // 중간보다 살짝 위 — 실기기 보행 테스트로 재보정이 필요하다.
  static const deviationSeverityThreshold = 0.80;
  // T42 재학습 후 none 데이터가 36→101장으로 늘며 softmax 확률이 더 분산돼
  // 0.65는 front 판정을 과도하게 "무판정(None)" 처리함 (recall 78.6%→57.1% 하락,
  // train/eval_model.py로 실측). 0.65→0.5로 낮춰 재측정 시 recall 89.3%,
  // precision 96.2% 유지 확인 (0.3~0.5 구간 동일한 결과).
  static const _frontThreshold = 0.5;
  static const _noneThreshold = 0.50;
  // T51 신설. **재학습 전 잠정값이다.** approach는 feedback_service.dart에서
  // none과 동일하게 침묵 처리되므로, none과 같은 값(0.50)에서 출발한다.
  // 확정값은 5-class 재학습 후 train/eval_model.py 진단 결과로 정한다.
  static const _approachThreshold = 0.50;

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

    // 재호출 이전 실행의 상태(일시정지/에러 전 프레임의 확률 벡터)가 남아 있으면
    // 재개 직후 스무딩 평균에 섞여 판정이 지연될 수 있으므로 초기화 시 비운다.
    _recentProbs.clear();
    _frameCount = 0;

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
      if (!hashMatches(modelBytes, hashFile)) {
        throw ModelIntegrityException(
          '모델 파일이 손상되었거나 변조되었습니다. 앱을 다시 설치해주세요.',
        );
      }
    } catch (e) {
      if (e is ModelIntegrityException) rethrow;
      // 해시 파일 없음 → 개발 환경, 건너뜀
    }
  }

  /// `expectedHashRaw`(해시 파일 원문)와 `modelBytes`의 실제 SHA-256을 비교한다.
  /// `_verifyModelIntegrity`에서 분리되어 있어 asset 로딩 없이도 단위 테스트가 가능하다.
  /// true = 검증 통과 또는 건너뜀(placeholder/형식 불일치), false = 해시 불일치(변조 의심).
  @visibleForTesting
  bool hashMatches(Uint8List modelBytes, String expectedHashRaw) {
    final expectedHash = expectedHashRaw.trim();

    // placeholder 해시이거나 형식이 다르면 검증 건너뜀 (더미 빌드 / 개발 환경)
    if (expectedHash.length != 64 || expectedHash == 'placeholder_hash')
      return true;

    final actualHash = sha256.convert(modelBytes).toString();
    return actualHash == expectedHash;
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
    final threshold = switch (label) {
      'front' => _frontThreshold,
      'none' => _noneThreshold,
      'approach' => _approachThreshold,
      _ => _deviationThreshold,
    };
    if (conf < threshold) return null;

    return ClassificationResult(label, conf);
  }

  Float32List? _preprocessCamera(CameraImage image) {
    try {
      img.Image? decoded;

      if (image.format.group == ImageFormatGroup.yuv420) {
        decoded = _convertYUV420(image);
      } else if (image.format.group == ImageFormatGroup.bgra8888) {
        decoded = convertBGRA8888(image);
      } else {
        return null;
      }

      final resized =
          img.copyResize(decoded, width: _inputSize, height: _inputSize);

      // NCHW 포맷 [1, 3, 224, 224] + ImageNet 정규화
      const mean = [0.485, 0.456, 0.406];
      const std = [0.229, 0.224, 0.225];

      final buffer = Float32List(3 * _inputSize * _inputSize);
      for (int y = 0; y < _inputSize; y++) {
        for (int x = 0; x < _inputSize; x++) {
          final pixel = resized.getPixel(x, y);
          final idx = y * _inputSize + x;
          buffer[0 * _inputSize * _inputSize + idx] =
              (pixel.r / 255.0 - mean[0]) / std[0];
          buffer[1 * _inputSize * _inputSize + idx] =
              (pixel.g / 255.0 - mean[1]) / std[1];
          buffer[2 * _inputSize * _inputSize + idx] =
              (pixel.b / 255.0 - mean[2]) / std[2];
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

  /// (T29) iOS BGRA8888 is a single plane. `image.planes[0].bytes` is a
  /// `Uint8List` *view* into a larger native `ByteBuffer` — its
  /// `offsetInBytes` is not guaranteed to be 0, and its row stride
  /// (`bytesPerRow`) is not guaranteed to equal `width * 4` (rows may be
  /// padded). Passing the raw `.buffer` with no offset/stride, as a
  /// previous version of this code did, would misalign pixels whenever
  /// either of those holds — this path was never exercised because the
  /// app currently forces `ImageFormatGroup.yuv420` in
  /// `camera_screen.dart`, but `img.Image.fromBytes` supports
  /// `bytesOffset`/`rowStride` params precisely for this case, so we
  /// pass them through explicitly to keep this path correct once iOS
  /// (yuv420 not supported there) reaches it (see Tasks.md T29/T33).
  ///
  /// Extracted from `_preprocessCamera` (behavior-preserving) so the
  /// buffer offset/row-stride handling can be unit tested without a real
  /// camera stream.
  @visibleForTesting
  img.Image convertBGRA8888(CameraImage image) {
    return img.Image.fromBytes(
      width: image.width,
      height: image.height,
      bytes: image.planes[0].bytes.buffer,
      bytesOffset: image.planes[0].bytes.offsetInBytes,
      rowStride: image.planes[0].bytesPerRow,
      order: img.ChannelOrder.bgra,
    );
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
        final g = (yVal - 0.344136 * (uVal - 128) - 0.714136 * (vVal - 128))
            .clamp(0, 255)
            .toInt();
        final b = (yVal + 1.772 * (uVal - 128)).clamp(0, 255).toInt();
        out.setPixelRgb(x, y, r, g, b);
      }
    }
    return out;
  }

  void dispose() {
    _session?.release();
    _session = null;
    if (_envInitialized) {
      OrtEnv.instance.release();
      _envInitialized = false;
    }
  }
}
