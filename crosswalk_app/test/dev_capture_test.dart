// B안 ① 개발 설정(초광각 0.6배·가로 장착·프레임 저장)의 순수 로직 테스트.
// 설계: train/phone_ultrawide/design.md §1·§2·§3.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:crosswalk_app/services/angle_estimator.dart';
import 'package:crosswalk_app/services/classifier.dart';
import 'package:crosswalk_app/services/dev_capture.dart';

/// 가로·세로가 다르고 픽셀마다 값이 다른 작은 그림(장면). r = x, g = y.
img.Image scene(int w, int h) {
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      im.setPixelRgb(x, y, x * 10, y * 10, 0);
    }
  }
  return im;
}

/// 시계방향 [deg]도 회전(`copyRotate` 관례). 0이면 복사본.
img.Image rot(img.Image im, int deg) =>
    deg % 360 == 0 ? im.clone() : img.copyRotate(im, angle: deg % 360);

bool samePixels(img.Image a, img.Image b) {
  if (a.width != b.width || a.height != b.height) return false;
  for (var y = 0; y < a.height; y++) {
    for (var x = 0; x < a.width; x++) {
      final p = a.getPixel(x, y), q = b.getPixel(x, y);
      if (p.r != q.r || p.g != q.g || p.b != q.b) return false;
    }
  }
  return true;
}

/// Y 평면만 값이 있는 YUV420 [CameraImage] (U·V = 128 → 회색).
CameraImage yuvImage(int w, int h) {
  final y = Uint8List(w * h);
  for (var i = 0; i < y.length; i++) {
    y[i] = i % 256;
  }
  final uv = Uint8List((w ~/ 2) * (h ~/ 2))..fillRange(0, (w ~/ 2) * (h ~/ 2), 128);
  return CameraImage.fromPlatformInterface(CameraImageData(
    format: const CameraImageFormat(ImageFormatGroup.yuv420, raw: 35),
    planes: [
      CameraImagePlane(bytes: y, bytesPerRow: w, bytesPerPixel: 1),
      CameraImagePlane(bytes: uv, bytesPerRow: w ~/ 2, bytesPerPixel: 1),
      CameraImagePlane(
          bytes: Uint8List.fromList(uv), bytesPerRow: w ~/ 2, bytesPerPixel: 1),
    ],
    width: w,
    height: h,
  ));
}

void main() {
  group('CameraMountRotations — 설정이 꺼져 있으면(세로) 지금 동작', () {
    test('세로: 각도·위치·노면 = 센서 회전, 분류기 = 0 (기존 호출과 같음)', () {
      expect(CameraMountRotations.of(CameraMount.portrait, 90),
          const CameraMountRotations(90, 0));
      expect(CameraMountRotations.of(CameraMount.portrait, 270),
          const CameraMountRotations(270, 0));
    });

    test('가로(센서 90, S25 울트라 기록값): 윗부분 왼쪽 (0, 270) / 오른쪽 (180, 90)',
        () {
      expect(CameraMountRotations.of(CameraMount.landscapeTopLeft, 90),
          const CameraMountRotations(0, 270));
      expect(CameraMountRotations.of(CameraMount.landscapeTopRight, 90),
          const CameraMountRotations(180, 90));
    });

    // 장면 S(똑바로 선 화면)를 세로/가로로 찍었을 때의 센서 버퍼를 만들고,
    // (1) upright 회전이 S로 되돌리는지, (2) 가로의 분류기 입력이 **세로 센서
    // 버퍼(= 분류기 학습 방향)** 와 같은지 본다.
    for (final mount in [
      CameraMount.landscapeTopLeft,
      CameraMount.landscapeTopRight,
    ]) {
      test('$mount: upright로 장면 복원, 분류기 입력 = 세로 센서 방향', () {
        const sensor = 90;
        final s = scene(6, 4);
        final r = CameraMountRotations.of(mount, sensor);
        // 세로 센서 버퍼 P: rot(P, sensor) = S
        final portraitBuf = rot(s, 360 - sensor);
        expect(samePixels(rot(portraitBuf, sensor), s), isTrue);
        // 가로 센서 버퍼 L: rot(L, upright) = S
        final landBuf = rot(s, 360 - r.upright);
        expect(samePixels(rot(landBuf, r.upright), s), isTrue);
        // 분류기: 가로 버퍼를 classifier만큼 돌리면 세로 버퍼(학습 방향)와 같다
        expect(samePixels(rot(landBuf, r.classifier), portraitBuf), isTrue);
      });
    }
  });

  group('Classifier.rotateModelInput', () {
    test('0이면 같은 객체를 그대로 돌려준다(세로 기본 동작 불변)', () {
      final im = scene(4, 4);
      expect(identical(Classifier.rotateModelInput(im, 0), im), isTrue);
      expect(identical(Classifier.rotateModelInput(im, 360), im), isTrue);
    });

    test('각도 모델 sensorCoord와 같은 시계방향 관례', () {
      final src = scene(5, 5);
      for (final deg in [90, 180, 270]) {
        final out = Classifier.rotateModelInput(src, deg);
        for (var dy = 0; dy < 5; dy++) {
          for (var dx = 0; dx < 5; dx++) {
            final s = AngleEstimator.sensorCoord(dx, dy, deg, 5, 5);
            final p = out.getPixel(dx, dy), q = src.getPixel(s[0], s[1]);
            expect([p.r, p.g], [q.r, q.g], reason: 'deg=$deg ($dx,$dy)');
          }
        }
      }
    });
  });

  group('ultraWideZoomTarget', () {
    test('최소 줌을 못 읽었거나 1 이상이면 null(0.6 불가)', () {
      expect(ultraWideZoomTarget(null), isNull);
      expect(ultraWideZoomTarget(1.0), isNull);
      expect(ultraWideZoomTarget(1.5), isNull);
    });
    test('최소 0.6 이하면 0.6, 0.6~1 사이면 그 최소값', () {
      expect(ultraWideZoomTarget(0.6), 0.6);
      expect(ultraWideZoomTarget(0.5), 0.6);
      expect(ultraWideZoomTarget(0.7), 0.7);
    });
  });

  group('devCaptureText (디버그 박스)', () {
    test('모두 꺼지면 빈 문자열 — 디버그 박스가 지금과 같다', () {
      expect(
          devCaptureText(
              ultraWide: false,
              zoomStatus: ZoomApplyStatus.off,
              mount: CameraMount.portrait,
              frameSave: false),
          '');
    });
    test('실패·불가가 보인다(조용히 1배로 돌지 않게)', () {
      expect(
          devCaptureText(
              ultraWide: true,
              zoomStatus: ZoomApplyStatus.failed,
              mount: CameraMount.portrait,
              frameSave: false),
          '초광각 0.6 실패!');
      expect(
          devCaptureText(
              ultraWide: true,
              zoomStatus: ZoomApplyStatus.unsupported,
              mount: CameraMount.portrait,
              frameSave: false),
          '초광각 0.6 불가');
    });
    test('켜진 것만 이어 붙인다', () {
      expect(
          devCaptureText(
              ultraWide: true,
              zoomStatus: ZoomApplyStatus.applied,
              zoomTarget: 0.6,
              mount: CameraMount.landscapeTopLeft,
              frameSave: true,
              savedFrames: 12),
          '초광각 0.60 요청됨 · 가로(위=왼) · 저장 12장');
      expect(
          devCaptureText(
              ultraWide: false,
              zoomStatus: ZoomApplyStatus.off,
              mount: CameraMount.landscapeTopRight,
              frameSave: true,
              savedFrames: 3,
              frameError: 'x'),
          '가로(위=오) · 저장 오류 3장');
    });
  });

  group('FramePacer — 1초에 1장', () {
    test('첫 프레임은 저장, 1초 안은 건너뜀, 1초가 되면 다시 저장', () {
      final p = FramePacer();
      expect(p.shouldSave(10000), isTrue);
      expect(p.shouldSave(10033), isFalse);
      expect(p.shouldSave(10999), isFalse);
      expect(p.shouldSave(11000), isTrue);
      expect(p.shouldSave(11500), isFalse);
      expect(p.shouldSave(12100), isTrue);
    });
    test('30fps 10초면 10장', () {
      final p = FramePacer();
      var n = 0;
      for (var i = 0; i < 300; i++) {
        if (p.shouldSave(i * 1000 ~/ 30)) n++;
      }
      expect(n, 10);
    });
    test('reset 뒤 첫 프레임은 바로 저장', () {
      final p = FramePacer();
      expect(p.shouldSave(5000), isTrue);
      p.reset();
      expect(p.shouldSave(5001), isTrue);
    });
  });

  group('FrameSaver.countToDelete — 용량 상한', () {
    test('상한 이하면 0', () {
      expect(FrameSaver.countToDelete([100, 100, 100], 300), 0);
      expect(FrameSaver.countToDelete(const [], 0), 0);
    });
    test('넘으면 오래된 것부터 상한 이하가 될 때까지', () {
      expect(FrameSaver.countToDelete([100, 100, 100], 250), 1);
      expect(FrameSaver.countToDelete([100, 100, 100], 199), 2);
      expect(FrameSaver.countToDelete([100, 100, 100], 50), 3);
    });
    test('기본 상한은 500MB', () {
      expect(FrameSaver.defaultMaxTotalBytes, 500 * 1024 * 1024);
    });
  });

  group('FrameSaver 이름', () {
    test('파일 이름 = 기록 t와 같은 epoch ms', () {
      final t = DateTime.fromMillisecondsSinceEpoch(1761030900123);
      expect(FrameSaver.fileNameFor(t), 'f_1761030900123.jpg');
    });
    test('묶음 폴더 이름은 이름순 = 시간순', () {
      expect(FrameSaver.sessionNameFor(DateTime(2026, 10, 21, 7, 5, 9)),
          '20261021_070509');
    });
  });

  group('FrameSaver 파일 쓰기(가짜 인코더)', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('frames_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('1초 간격만 저장하고, 상한을 넘으면 오래된 것부터 지운다', () async {
      final saver = FrameSaver(
        baseDir: () async => tmp,
        maxTotalBytes: 250,
        encode: (_) async => Uint8List(100),
      );
      final t0 = DateTime(2026, 10, 21, 12);
      await saver.start(t0);
      final image = yuvImage(4, 4);
      final results = <FrameSaveResult>[];
      for (var i = 0; i < 4; i++) {
        final t = t0.add(Duration(milliseconds: 1000 * i));
        // 고정 대기(20ms) 대신 저장 완료를 기다린다 — 실제 파일 쓰기·삭제가
        // 느리면 다음 저장이 '바쁨'으로 건너뛰어져 가끔 실패했다(CI 39604916380).
        final done = Completer<void>();
        expect(
            saver.maybeSave(image, t, onDone: (r) {
              results.add(r);
              done.complete();
            }),
            isTrue);
        await done.future;
        // 같은 초 안의 다음 프레임은 건너뛴다
        expect(saver.maybeSave(image, t.add(const Duration(milliseconds: 33))),
            isFalse);
      }
      expect(results.every((r) => r.ok), isTrue);
      expect(saver.savedCount, 4);
      // 100B × 4 = 400 > 250 → 오래된 2장 삭제, 2장 남음
      final left = saver.sessionDir!
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .toList()
        ..sort();
      expect(left, [
        FrameSaver.fileNameFor(t0.add(const Duration(seconds: 2))),
        FrameSaver.fileNameFor(t0.add(const Duration(seconds: 3))),
      ]);
      expect(saver.totalBytes, 200);
      expect((await saver.latestSessionFiles()).length, 2);
    });

    test('시작 전·멈춘 뒤에는 저장하지 않는다(기본 꺼짐)', () async {
      final saver = FrameSaver(
        baseDir: () async => tmp,
        encode: (_) async => Uint8List(10),
      );
      final image = yuvImage(4, 4);
      expect(saver.maybeSave(image, DateTime(2026)), isFalse);
      await saver.start(DateTime(2026, 10, 21));
      saver.stop();
      expect(saver.maybeSave(image, DateTime(2026, 10, 21, 1)), isFalse);
      expect(Directory('${tmp.path}/frames').listSync(recursive: true)
          .whereType<File>(), isEmpty);
    });
  });

  test('encodeYuvJpeg: 원본 해상도 그대로(회전 없음) JPEG', () {
    final f = YuvFrame.fromCameraImage(yuvImage(8, 6))!;
    final decoded = img.decodeJpg(encodeYuvJpeg(f))!;
    expect([decoded.width, decoded.height], [8, 6]);
  });
}
