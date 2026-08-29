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
    //
    // T66-4: 이전에는 `state % 256`으로 **하위 8비트**를 썼는데, LCG는
    // 하위 비트의 주기가 짧아 그게 곧 규칙적인 패턴이 된다 — 즉 "무작위
    // 노이즈"가 아니라 약한 방향성을 가진 무늬였다. 창을 ±3도로 좁게
    // 잡았을 땐 그 구조가 신뢰도에 안 잡혀 문제가 드러나지 않았지만,
    // ±10도로 넓히자 4개 시드 중 3개가 방향으로 **오탐**됐다(파이썬으로
    // 같은 알고리즘을 돌려 실측: conf 0.216/0.249/0.222 > 임계값 0.2).
    // 상위 비트를 쓰면 그 구조가 사라진다(같은 조건에서 0.152~0.177로
    // 전부 정상 거부).
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    buf[i] = (state >> 16) & 0xFF;
  }
  return buf;
}

/// T66-4 회귀 방지용: **실제 카메라 조건**에 가까운 줄무늬를 만든다 —
/// (1) 원근 왜곡(아래로 갈수록 줄 간격이 넓어지고 각도가 달라짐),
/// (2) 갈라진 페인트를 흉내 낸 잡음.
///
/// 이상적인 평행 줄무늬(`_makeStripes`)만으로 검증했을 때 이 조건에서
/// 계속 무판정(`lowConfidence`)이 나는 문제를 놓쳤다(2026-08-24 사용자
/// 실기기 사진 3장에서 발견). 이 생성기가 그 상황을 테스트로 고정한다.
Uint8List _makePerspectiveStripes({
  required int width,
  required int height,
  required double angleDegrees,
  double period = 24,
  double vanishY = -120,
  double crackAmplitude = 0,
  int seed = 7,
}) {
  final buf = Uint8List(width * height);
  final rad = angleDegrees * math.pi / 180;
  final sinE = math.sin(rad);
  final cosE = math.cos(rad);
  var state = seed;
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final p = -x * sinE + y * cosE;
      // 소실점 기준 원근 압축 — 위쪽은 촘촘, 아래쪽은 성기게.
      final phase = (p / (y - vanishY)) * 3000.0 / period;
      var value = 128 + 110 * math.sin(2 * math.pi * phase);
      if (crackAmplitude > 0) {
        state = (state * 1103515245 + 12345) & 0x7fffffff;
        // -1..1 범위의 결정적 잡음.
        final n = (state % 2000) / 1000.0 - 1.0;
        value += n * crackAmplitude;
      }
      buf[y * width + x] = value.round().clamp(0, 255);
    }
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

  group('StripeDirectionEstimator.diagnose — T66-3 무판정 이유 구분', () {
    test('에지가 없으면 noEdges를 반환한다', () {
      final gray = _makeFlat(width, height, 128);
      final d = StripeDirectionEstimator.diagnose(
        gray: gray,
        width: width,
        height: height,
        rowStride: width,
      );
      expect(d.estimate, isNull);
      expect(d.reason, StripeDirectionNullReason.noEdges);
      expect(d.rejectedAngleDegrees, isNull);
    });

    test('우세 방향이 근수직이면 tooVertical과 걸러진 각도를 반환한다', () {
      final gray = _makeStripes(
        width: width,
        height: height,
        angleDegrees: 80.0,
      );
      final d = StripeDirectionEstimator.diagnose(
        gray: gray,
        width: width,
        height: height,
        rowStride: width,
        maxTiltDegrees: 60.0,
      );
      expect(d.estimate, isNull);
      expect(d.reason, StripeDirectionNullReason.tooVertical);
      expect(d.rejectedAngleDegrees, closeTo(80.0, 3.0));
    });

    test('우세 방향이 흩어져 있으면 lowConfidence를 반환한다', () {
      final gray = _makeNoise(width, height, 42);
      final d = StripeDirectionEstimator.diagnose(
        gray: gray,
        width: width,
        height: height,
        rowStride: width,
      );
      expect(d.estimate, isNull);
      expect(d.reason, StripeDirectionNullReason.lowConfidence);
    });

    test('뚜렷한 각도가 있으면 reason은 none이고 estimate가 채워진다', () {
      final gray = _makeStripes(
        width: width,
        height: height,
        angleDegrees: 20.0,
      );
      final d = StripeDirectionEstimator.diagnose(
        gray: gray,
        width: width,
        height: height,
        rowStride: width,
      );
      expect(d.reason, StripeDirectionNullReason.none);
      expect(d.estimate, isNotNull);
      expect(d.estimate!.angleDegrees, closeTo(20.0, 3.0));
    });
  });

  group('StripeDirectionEstimator — T66-4 원근·균열 조건 (실기기 회귀)', () {
    // 사용자 실기기 사진 3장에서 "심하게 이탈" 판정인데도 각도가 계속
    // 무판정으로 나온 상황. 원인은 필터가 아니라 신뢰도 창(±3도)이 원근
    // 왜곡과 갈라진 페인트로 퍼진 에지 방향을 담지 못한 것이었다.
    test('원근 왜곡만 있어도 무판정이 아니어야 한다', () {
      final gray = _makePerspectiveStripes(
        width: width,
        height: height,
        angleDegrees: 20,
      );
      final d = StripeDirectionEstimator.diagnose(
        gray: gray,
        width: width,
        height: height,
        rowStride: width,
      );
      expect(
        d.reason,
        StripeDirectionNullReason.none,
        reason: '원근이 있는 실제 횡단보도에서 무판정이 나면 안 된다',
      );
      expect(d.estimate, isNotNull);
    });

    test('원근 + 갈라진 페인트 조건에서도 무판정이 아니어야 한다', () {
      for (final crack in [30.0, 50.0]) {
        final gray = _makePerspectiveStripes(
          width: width,
          height: height,
          angleDegrees: 20,
          crackAmplitude: crack,
        );
        final d = StripeDirectionEstimator.diagnose(
          gray: gray,
          width: width,
          height: height,
          rowStride: width,
        );
        expect(
          d.reason,
          StripeDirectionNullReason.none,
          reason: '균열강도 $crack에서 무판정이 나면 안 된다',
        );
      }
    });

    test('창을 ±3도로 되돌리면 무판정이 재현된다 (원인 고정)', () {
      // 이 테스트는 "왜 10인가"의 근거를 코드로 남긴다 — 창을 좁히면
      // 실제로 무판정이 나므로, 누군가 값을 되돌리면 여기서 드러난다.
      final gray = _makePerspectiveStripes(
        width: width,
        height: height,
        angleDegrees: 20,
        crackAmplitude: 50,
      );
      final d = StripeDirectionEstimator.diagnose(
        gray: gray,
        width: width,
        height: height,
        rowStride: width,
        angleWindowDegrees: 3,
      );
      expect(d.reason, StripeDirectionNullReason.lowConfidence);
    });

    test('창을 넓혀도 무작위 노이즈는 여전히 걸러진다 (오탐 방지)', () {
      // ±12도 이상으로 넓히면 노이즈까지 통과해버린다 — 10이 상한인 이유.
      for (final seed in [42, 1, 99, 2024]) {
        final gray = _makeNoise(width, height, seed);
        final d = StripeDirectionEstimator.diagnose(
          gray: gray,
          width: width,
          height: height,
          rowStride: width,
        );
        expect(
          d.estimate,
          isNull,
          reason: 'seed $seed 노이즈가 방향으로 오탐되면 안 된다',
        );
      }
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
