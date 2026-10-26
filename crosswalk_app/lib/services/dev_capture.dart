import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// 하드웨어 1단계 B안 ①: 데이터 수집용 개발 설정(초광각 0.6배·가로 장착·프레임
/// 저장). 설계 `train/phone_ultrawide/design.md` §1·§2·§3. 세 설정 모두 **기본 꺼짐**이고,
/// 꺼져 있으면 지금 앱 동작이 바뀌지 않는다.

/// 폰을 어떻게 들었나(장착 방향). 방향은 **화면을 보는 사람 기준**이다 — 가슴에
/// 달면 화면이 사용자 쪽, 카메라가 앞쪽을 본다.
enum CameraMount {
  /// 세로(지금 앱, 기본).
  portrait,

  /// 가로 — 폰 윗부분이 왼쪽(세로에서 반시계 90°, 안드로이드 ROTATION_90).
  landscapeTopLeft,

  /// 가로 — 폰 윗부분이 오른쪽(세로에서 시계 90°, 안드로이드 ROTATION_270).
  landscapeTopRight,
}

/// 모델별 입력 회전(시계방향, 도). `AngleEstimator.sensorCoord`와 같은 관례.
class CameraMountRotations {
  const CameraMountRotations(this.upright, this.classifier);

  /// 각도·위치·노면 모델: 센서 버퍼를 "똑바로 선 화면"으로 만드는 회전.
  /// 이 세 모델은 EXIF 보정된(똑바로 선) 사진으로 학습했다.
  final int upright;

  /// 분류 모델: 학습 입력이 **세로 사진의 센서 방향**(= 똑바로 선 화면을
  /// 반시계 90° 돌린 상태, `train/h0_t109/aspect_cmp/results.md` §1)이라
  /// 가로 장착이면 같은 방향으로 맞춰 돌린다. 세로는 0(지금 동작).
  final int classifier;

  /// 판정표:
  /// | 장착 | upright | classifier |
  /// |---|---|---|
  /// | 세로 | sensor | 0 (지금 그대로) |
  /// | 가로·윗부분 왼쪽 | (sensor − 90) mod 360 | (upright + 270) mod 360 |
  /// | 가로·윗부분 오른쪽 | (sensor − 270) mod 360 | (upright + 270) mod 360 |
  ///
  /// upright는 안드로이드 후면 카메라 공식 `(sensor − 화면회전) mod 360`
  /// (화면회전: 윗부분 왼쪽 = 90, 오른쪽 = 270). sensor 90(갤럭시 S25 울트라 기록)
  /// 이면 윗부분 왼쪽 = (0, 270), 오른쪽 = (180, 90).
  static CameraMountRotations of(CameraMount mount, int sensorOrientation) {
    final s = sensorOrientation % 360;
    switch (mount) {
      case CameraMount.portrait:
        return CameraMountRotations(s, 0);
      case CameraMount.landscapeTopLeft:
        final u = (s - 90 + 360) % 360;
        return CameraMountRotations(u, (u + 270) % 360);
      case CameraMount.landscapeTopRight:
        final u = (s - 270 + 360) % 360;
        return CameraMountRotations(u, (u + 270) % 360);
    }
  }

  @override
  bool operator ==(Object other) =>
      other is CameraMountRotations &&
      other.upright == upright &&
      other.classifier == classifier;

  @override
  int get hashCode => Object.hash(upright, classifier);

  @override
  String toString() => 'CameraMountRotations($upright, $classifier)';
}

/// 초광각 개발 설정이 요청하는 줌 값.
const double ultraWideZoom = 0.6;

/// 초광각 설정이 실제로 걸 줌 값. 최소 줌이 1 이상(초광각 불가)이거나 못 읽었으면
/// null — 설정을 무시하고 "0.6 불가"로 표시한다(설계 §1-3). 최소 줌이 0.6보다
/// 작아도 0.6을 쓴다(수집 데이터의 화각을 하나로 고정).
double? ultraWideZoomTarget(double? zoomMin) {
  if (zoomMin == null || zoomMin >= 1.0) return null;
  return zoomMin > ultraWideZoom ? zoomMin : ultraWideZoom;
}

/// 초광각 설정 결과. 플러그인이 현재 줌을 돌려주지 않으므로(설계 §1-3)
/// "요청 + 예외/에러 스트림 여부"까지만 안다 — 실제 렌즈 전환은 저장 프레임으로 판정.
enum ZoomApplyStatus { off, applied, unsupported, failed }

/// 디버그 박스의 개발 설정 줄. 세 설정이 모두 꺼져 있으면 빈 문자열 —
/// 디버그 박스가 지금과 같다.
String devCaptureText({
  required bool ultraWide,
  required ZoomApplyStatus zoomStatus,
  double? zoomTarget,
  required CameraMount mount,
  required bool frameSave,
  int savedFrames = 0,
  String? frameError,
}) {
  final parts = <String>[];
  if (ultraWide) {
    switch (zoomStatus) {
      case ZoomApplyStatus.applied:
        parts.add('초광각 ${zoomTarget?.toStringAsFixed(2) ?? '-'} 요청됨');
      case ZoomApplyStatus.unsupported:
        parts.add('초광각 0.6 불가');
      case ZoomApplyStatus.failed:
        parts.add('초광각 0.6 실패!');
      case ZoomApplyStatus.off:
        parts.add('초광각 대기');
    }
  }
  if (mount != CameraMount.portrait) {
    parts.add(mount == CameraMount.landscapeTopLeft ? '가로(위=왼)' : '가로(위=오)');
  }
  if (frameSave) {
    parts.add(frameError == null ? '저장 $savedFrames장' : '저장 오류 $savedFrames장');
  }
  return parts.join(' · ');
}

/// 프레임 저장 주기 판정(1초에 1장). 시계는 밀리초 정수로 받는다(테스트용).
class FramePacer {
  FramePacer({this.intervalMs = 1000});

  final int intervalMs;
  int? _lastMs;

  /// 이번 프레임을 저장할 차례인가. 차례면 시각을 기억한다.
  bool shouldSave(int nowMs) {
    final last = _lastMs;
    if (last != null && nowMs - last < intervalMs) return false;
    _lastMs = nowMs;
    return true;
  }

  void reset() => _lastMs = null;
}

/// 저장 한 장에 필요한 YUV420 평면 사본. 콜백이 끝나면 카메라 버퍼가 재사용되므로
/// 그 안에서 복사해 두고 인코딩은 다른 isolate에서 한다.
class YuvFrame {
  const YuvFrame({
    required this.width,
    required this.height,
    required this.y,
    required this.u,
    required this.v,
    required this.yStride,
    required this.uvStride,
    required this.uvPixelStride,
  });

  final int width;
  final int height;
  final Uint8List y;
  final Uint8List u;
  final Uint8List v;
  final int yStride;
  final int uvStride;
  final int uvPixelStride;

  /// YUV420이 아니면 null(이 앱은 yuv420만 쓴다 — `camera_screen.dart`).
  static YuvFrame? fromCameraImage(CameraImage image) {
    if (image.format.group != ImageFormatGroup.yuv420) return null;
    if (image.planes.length < 3) return null;
    return YuvFrame(
      width: image.width,
      height: image.height,
      y: Uint8List.fromList(image.planes[0].bytes),
      u: Uint8List.fromList(image.planes[1].bytes),
      v: Uint8List.fromList(image.planes[2].bytes),
      yStride: image.planes[0].bytesPerRow,
      uvStride: image.planes[1].bytesPerRow,
      uvPixelStride: image.planes[1].bytesPerPixel ?? 1,
    );
  }
}

/// 센서 방향 그대로(회전 없음), 원본 해상도로 JPEG를 만든다. 색 변환 식은
/// 분류기 `_convertYUV420`과 같다 — 저장 프레임 = 분류기가 줄이기 직전 입력.
Uint8List encodeYuvJpeg(YuvFrame f, {int quality = 90}) {
  final out = img.Image(width: f.width, height: f.height);
  for (int y = 0; y < f.height; y++) {
    for (int x = 0; x < f.width; x++) {
      final yIdx = y * f.yStride + x;
      final uvIdx = (y ~/ 2) * f.uvStride + (x ~/ 2) * f.uvPixelStride;
      if (yIdx >= f.y.length || uvIdx >= f.u.length || uvIdx >= f.v.length) {
        continue;
      }
      final yVal = f.y[yIdx];
      final uVal = f.u[uvIdx];
      final vVal = f.v[uvIdx];
      final r = (yVal + 1.402 * (vVal - 128)).clamp(0, 255).toInt();
      final g = (yVal - 0.344136 * (uVal - 128) - 0.714136 * (vVal - 128))
          .clamp(0, 255)
          .toInt();
      final b = (yVal + 1.772 * (uVal - 128)).clamp(0, 255).toInt();
      out.setPixelRgb(x, y, r, g, b);
    }
  }
  return img.encodeJpg(out, quality: quality);
}

/// 한 장 저장 결과(기록용).
class FrameSaveResult {
  const FrameSaveResult({
    required this.file,
    required this.ok,
    this.bytes = 0,
    this.durMs = 0,
    this.deleted = 0,
    this.error,
  });

  final String file;
  final bool ok;
  final int bytes;
  final int durMs;
  final int deleted;
  final String? error;
}

/// 모델이 받는 프레임을 1초에 1장 JPEG로 앱 전용 폴더에 저장한다(B안 ①(d)).
///
/// - 위치: `getApplicationSupportDirectory()/frames/<켠 시각>/f_<t>.jpg` — 기록과 같은
///   앱 전용 폴더(다른 앱은 못 읽음). `t`는 기록 `t`와 같은 폰 시계 epoch ms.
/// - 용량 상한 [maxTotalBytes](기본 500MB): 넘으면 오래된(이름이 앞선) 것부터 지운다.
/// - 밖으로는 설정의 "프레임 보내기"(사용자가 고른 앱)로만 나간다. 인터넷 권한 없음.
class FrameSaver {
  FrameSaver({
    Future<Directory> Function()? baseDir,
    this.maxTotalBytes = defaultMaxTotalBytes,
    FramePacer? pacer,
    Future<Uint8List> Function(YuvFrame frame)? encode,
  })  : _baseDir = baseDir ?? getApplicationSupportDirectory,
        pacer = pacer ?? FramePacer(),
        _encode = encode ?? _encodeInIsolate;

  static const defaultMaxTotalBytes = 500 * 1024 * 1024;

  final Future<Directory> Function() _baseDir;
  final int maxTotalBytes;
  final FramePacer pacer;
  final Future<Uint8List> Function(YuvFrame frame) _encode;

  static Future<Uint8List> _encodeInIsolate(YuvFrame frame) =>
      Isolate.run(() => encodeYuvJpeg(frame));

  Directory? _sessionDir;
  Directory? get sessionDir => _sessionDir;
  bool get isStarted => _sessionDir != null;

  /// 오래된 것부터: (경로, 크기). 이름순 = 시간순.
  final List<MapEntry<String, int>> _files = [];
  int _total = 0;
  int get totalBytes => _total;

  bool _busy = false;
  int savedCount = 0;
  int skippedBusy = 0;
  String? lastError;

  /// 저장 폴더를 만들고 기존 프레임 크기를 읽는다. 이미 시작했으면 아무것도 안 한다.
  Future<void> start(DateTime now) async {
    if (_sessionDir != null) return;
    final base = await _baseDir();
    final root = Directory('${base.path}${Platform.pathSeparator}frames');
    await root.create(recursive: true);
    _files.clear();
    _total = 0;
    await for (final e in root.list(recursive: true)) {
      if (e is File && e.path.endsWith('.jpg')) {
        final size = await e.length();
        _files.add(MapEntry(e.path, size));
        _total += size;
      }
    }
    _files.sort((a, b) => a.key.compareTo(b.key));
    final dir = Directory(
        '${root.path}${Platform.pathSeparator}${sessionNameFor(now)}');
    await dir.create(recursive: true);
    _sessionDir = dir;
    savedCount = 0;
    skippedBusy = 0;
    lastError = null;
    pacer.reset();
    await _prune();
  }

  void stop() {
    _sessionDir = null;
  }

  /// 차례면 평면을 복사하고 저장을 시작한다(기다리지 않음). 저장이 끝나면 [onDone].
  /// 프레임 콜백 안에서 부른다 — 예외를 밖으로 내지 않는다.
  bool maybeSave(CameraImage image, DateTime now,
      {void Function(FrameSaveResult result)? onDone}) {
    final dir = _sessionDir;
    if (dir == null) return false;
    if (!pacer.shouldSave(now.millisecondsSinceEpoch)) return false;
    if (_busy) {
      skippedBusy++;
      return false;
    }
    final YuvFrame? frame;
    try {
      frame = YuvFrame.fromCameraImage(image);
    } catch (e) {
      lastError = '$e';
      return false;
    }
    if (frame == null) {
      lastError = 'format ${image.format.group.name}';
      return false;
    }
    _busy = true;
    unawaited(_write(dir, frame, now).then((r) {
      _busy = false;
      onDone?.call(r);
    }));
    return true;
  }

  Future<FrameSaveResult> _write(
      Directory dir, YuvFrame frame, DateTime now) async {
    final name = fileNameFor(now);
    final clock = Stopwatch()..start();
    try {
      final bytes = await _encode(frame);
      final path = '${dir.path}${Platform.pathSeparator}$name';
      await File(path).writeAsBytes(bytes, flush: true);
      _files.add(MapEntry(path, bytes.length));
      _total += bytes.length;
      final deleted = await _prune();
      savedCount++;
      lastError = null;
      return FrameSaveResult(
          file: name,
          ok: true,
          bytes: bytes.length,
          durMs: clock.elapsedMilliseconds,
          deleted: deleted);
    } catch (e) {
      lastError = '$e';
      return FrameSaveResult(
          file: name, ok: false, durMs: clock.elapsedMilliseconds, error: '$e');
    }
  }

  Future<int> _prune() async {
    final n = countToDelete([for (final e in _files) e.value], maxTotalBytes);
    for (var i = 0; i < n; i++) {
      final e = _files.removeAt(0);
      _total -= e.value;
      try {
        await File(e.key).delete();
      } catch (_) {
        // 이미 없으면 그대로 둔다(합계에서는 뺐다)
      }
    }
    return n;
  }

  /// 공유용: 가장 최근 저장 폴더의 프레임(오래된 것부터).
  Future<List<File>> latestSessionFiles() async {
    final base = await _baseDir();
    final root = Directory('${base.path}${Platform.pathSeparator}frames');
    if (!await root.exists()) return const <File>[];
    final dirs = <Directory>[];
    await for (final e in root.list()) {
      if (e is Directory) dirs.add(e);
    }
    dirs.sort((a, b) => a.path.compareTo(b.path));
    for (final d in dirs.reversed) {
      final files = <File>[];
      await for (final e in d.list()) {
        if (e is File && e.path.endsWith('.jpg')) files.add(e);
      }
      if (files.isNotEmpty) {
        files.sort((a, b) => a.path.compareTo(b.path));
        return files;
      }
    }
    return const <File>[];
  }

  /// T135 공유 고르기용: 묶음 폴더 경로 → 그 안의 프레임(오래된 것부터).
  /// 프레임이 없는 폴더도 빈 목록으로 넣는다.
  Future<Map<String, List<File>>> sessionFiles() async {
    final base = await _baseDir();
    final root = Directory('${base.path}${Platform.pathSeparator}frames');
    if (!await root.exists()) return const <String, List<File>>{};
    final out = <String, List<File>>{};
    await for (final e in root.list()) {
      if (e is! Directory) continue;
      final files = <File>[];
      await for (final f in e.list()) {
        if (f is File && f.path.endsWith('.jpg')) files.add(f);
      }
      files.sort((a, b) => a.path.compareTo(b.path));
      out[e.path] = files;
    }
    return out;
  }

  /// 오래된 것부터 [sizes]를 몇 개 지워야 합계가 [maxTotalBytes] 이하가 되나.
  @visibleForTesting
  static int countToDelete(List<int> sizes, int maxTotalBytes) {
    var total = sizes.fold<int>(0, (a, b) => a + b);
    var n = 0;
    while (n < sizes.length && total > maxTotalBytes) {
      total -= sizes[n];
      n++;
    }
    return n;
  }

  /// `f_1761030900123.jpg` — 기록 `t`와 같은 epoch ms. 13자리라 이름순 = 시간순.
  @visibleForTesting
  static String fileNameFor(DateTime t) => 'f_${t.millisecondsSinceEpoch}.jpg';

  /// `20261021_171500` — 저장을 켠 시각(폰 시계).
  @visibleForTesting
  static String sessionNameFor(DateTime t) {
    String d2(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${d2(t.month)}${d2(t.day)}_'
        '${d2(t.hour)}${d2(t.minute)}${d2(t.second)}';
  }
}
