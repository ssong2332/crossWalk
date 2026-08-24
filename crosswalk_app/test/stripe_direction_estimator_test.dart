// T66 프로토타입 검증. `StripeDirectionEstimator`는 실제 카메라 프레임이
// 아니라 **합성(이상적) 줄무늬 패턴**으로만 검증한다 — 원근 왜곡, 그림자,
// 저조도 노이즈 등 실제 조건은 이 테스트로 확인할 수 없다(카메라 기기
// 없음, docs/Tasks.md T66 CAVEAT).
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/services/stripe_direction_estimator.dart';

/// 경계선이 수평(0도) 기준 [angleDegrees]도로 기울어진 줄무늬 그레이스케일
/// 버퍼를 만든다. period는 줄무늬 폭(픽셀).
///
/// 흑백 하드 스레숄드(계단 함수) 대신 **연속 사인파 밝기**를 쓴다 — 하드
/// 스레숄드로 대각선을 그리면 픽셀 격자 위에서 실제로는 계단(staircase)이
/// 되어, 국소적으로는 가로/세로 미세 계단만 보이고 의도한 대각선 방향이
/// 아닌 값(예: 15도 의도 → 0도로 앨리어싱, 35도 의도 → 45도로 앨리어싱)이
/// 나온다 — 실측(CI, 2026-08-24)으로 확인된 문제. 사인파는 모든 지점에서
/// 그라디언트 방향이 이론값과 정확히 일치하는 매끈한 함수라 이 앨리어싱이
/// 없다.
Uint8List _makeStripes({
  required int width,
  required int height,
  required double angleDegrees,
  double period = 24,
}) {
  final buf = Uint8List(width * height);
  final rad = angleDegrees * math.pi / 180;
  final sinE = math.sin(rad);
  final cosE = math.cos(rad);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final p = -x * sinE + y * cosE;
      final value = 128 + 110 * math.sin(2 * math.pi * p / period);
      buf[y * width + x] = value.round().clamp(0, 255);
    }
  }
  return buf;
}

Uint8List _makeFlat(int width, int height, int value) {
  return Uint8List(width * height)..fillRange(0, width * height, value);
}

Uint8List _makeNoise(int width, int height, int seed) {
  final buf = Uint8List(width * height);
  var state = seed;
  for (int i = 0; i < buf.length; i++) {
    // 간단한 선형 합동 난수 — 외부 패키지 의존 없이 결정적 노이즈 생성.
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    buf[i] = state % 256;
  }
  return buf;
}

void main() {
  const width = 200;
  const height = 150;

  group('StripeDirectionEstimator.estimate — 합성 줄무늬 각도', () {
    for (final angle in [0.0, 15.0, -15.0, 35.0, -35.0]) {
      test('경계선 각도 ${angle}도 패턴에서 근사 추정', () {
        final gray = _makeStripes(
          width: width,
          height: height,
          angleDegrees: angle,
        );

        final result = StripeDirectionEstimator.estimate(
          gray: gray,
          width: width,
          height: height,
          rowStride: width,
        );

        expect(result, isNotNull, reason: '뚜렷한 줄무늬 패턴은 null이면 안 된다');
        // 합성 패턴은 완벽한 기하 도형이라 오차를 좁게 잡을 수 있다 — 실제
        // 카메라 프레임에서는 이 허용 오차가 훨씬 커야 할 것이다(미검증).
        expect(result!.angleDegrees, closeTo(angle, 3.0));
        // 매끈한 사인파 패턴은 모든 지점의 그라디언트 방향이 이론상 동일해
        // 집중도(신뢰도)가 매우 높게 나와야 정상이다 — 낮게 나오면 계산에
        // 문제가 있다는 신호.
        expect(result.confidence, greaterThan(0.5));
      });
    }
  });

  group('StripeDirectionEstimator.estimate — 신뢰도 없음(무판정)', () {
    test('완전히 평평한 이미지는 null을 반환한다(에지 없음)', () {
      final gray = _makeFlat(width, height, 128);
      final result = StripeDirectionEstimator.estimate(
        gray: gray,
        width: width,
        height: height,
        rowStride: width,
      );
      expect(result, isNull);
    });

    test('무작위 노이즈 이미지는 null을 반환한다(우세 방향 없음)', () {
      final gray = _makeNoise(width, height, 42);
      final result = StripeDirectionEstimator.estimate(
        gray: gray,
        width: width,
        height: height,
        rowStride: width,
      );
      expect(result, isNull);
    });

    test('60도에 가까운(거의 수직) 줄무늬는 배경 구조물로 간주해 제외한다', () {
      final gray = _makeStripes(
        width: width,
        height: height,
        angleDegrees: 80.0,
      );
      final result = StripeDirectionEstimator.estimate(
        gray: gray,
        width: width,
        height: height,
        rowStride: width,
        maxTiltDegrees: 60.0,
      );
      expect(result, isNull);
    });
  });

  group('StripeDirectionEstimator.estimate — rowStride 처리', () {
    test('rowStride가 width보다 큰 패딩된 버퍼도 정확히 읽는다', () {
      const stride = width + 16; // 카메라 프레임처럼 행 사이 패딩이 있는 경우
      final packed = _makeStripes(
        width: width,
        height: height,
        angleDegrees: 20.0,
      );
      final padded = Uint8List(stride * height);
      for (int y = 0; y < height; y++) {
        padded.setRange(
          y * stride,
          y * stride + width,
          packed,
          y * width,
        );
      }

      final result = StripeDirectionEstimator.estimate(
        gray: padded,
        width: width,
        height: height,
        rowStride: stride,
      );

      expect(result, isNotNull);
      expect(result!.angleDegrees, closeTo(20.0, 3.0));
    });
  });
}
