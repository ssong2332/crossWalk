import 'package:crosswalk_app/services/direction_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

// T87: 방향은 각도 모델이 정한다. 근거(누수 없는 CV, front/left/right 445장):
// 분류기 84.5% vs 각도만(|a|<15 → front) 94.4%.
void main() {
  const t = DirectionResolver.deviationAngleDegrees;

  group('DirectionResolver.resolve (T87 판정표)', () {
    test('none/approach는 각도와 무관하게 그대로', () {
      for (final label in ['none', 'approach']) {
        for (final a in <double?>[null, 40, -40, 0]) {
          expect(DirectionResolver.resolve(label, a), label,
              reason: '$label/$a');
        }
      }
    });

    test('횡단보도 위인데 각도가 없으면 분류기 방향 그대로', () {
      for (final label in ['front', 'left', 'right']) {
        expect(DirectionResolver.resolve(label, null), label, reason: label);
      }
    });

    test('|각도| < 8.5 이면(직전 이탈 아님) 분류기가 뭐라 했든 front', () {
      // 실기기 #29: 직진인데 "오른쪽으로 틀어짐", 각도 2 -> front.
      // T103: 기준 15 -> 12. T160: 12 -> 8.5(T159 CV 문턱).
      expect(t, 8.5);
      for (final label in ['front', 'left', 'right']) {
        for (final a in <double>[0, 2, -2, 5.4, -5.4, 8.4, -8.4]) {
          expect(DirectionResolver.resolve(label, a), 'front',
              reason: '$label/$a');
        }
      }
    });

    test('각도 >= +8.5 이면 left(오른쪽으로 가라), <= -8.5 이면 right', () {
      for (final label in ['front', 'left', 'right']) {
        expect(DirectionResolver.resolve(label, t), 'left', reason: label);
        expect(DirectionResolver.resolve(label, 40), 'left', reason: label);
        expect(DirectionResolver.resolve(label, -t), 'right', reason: label);
        expect(DirectionResolver.resolve(label, -40), 'right', reason: label);
      }
    });

    test('실기기 #14: 분류기 right인데 각도 +40 -> left', () {
      expect(DirectionResolver.resolve('right', 40), 'left');
    });

    test('실기기 #11/#24: 분류기 front인데 각도 +18/+22 -> left', () {
      expect(DirectionResolver.resolve('front', 18), 'left');
      expect(DirectionResolver.resolve('front', 22), 'left');
    });
  });

  test('isOnCrosswalk', () {
    for (final l in ['front', 'left', 'right']) {
      expect(DirectionResolver.isOnCrosswalk(l), isTrue);
    }
    for (final l in ['none', 'approach', 'nocall', 'error']) {
      expect(DirectionResolver.isOnCrosswalk(l), isFalse);
    }
  });

  // T98: 끝이면 각도와 무관하게 중앙 쪽으로 (사용자 최종 목표, 2026-09-19).
  // T146: 끝 규칙(T98/T100/T137/T143의 ±20 고정·'이미 틀었음' 12~25·상한 25/21)을
  // 보정각 c = 각도 ± 20으로 바꿨다. 단계도 |c|로 정한다.
  group('DirectionResolver T146 끝 판정 떨림 방지 (B: 들어갈 때 1.0 / 나올 때 0.8)', () {
    test('상수: 나올 때 0.8 < 들어갈 때 1.0', () {
      expect(DirectionResolver.edgePosition, 1.0);
      expect(DirectionResolver.edgeExitPosition, 0.8);
    });

    test('끝이 아니었으면 |p| >= 1.0부터 끝', () {
      expect(DirectionResolver.edgeSide(null), 0);
      expect(DirectionResolver.edgeSide(0), 0);
      expect(DirectionResolver.edgeSide(-0.99), 0);
      expect(DirectionResolver.edgeSide(0.99), 0);
      expect(DirectionResolver.edgeSide(-1.0), -1);
      expect(DirectionResolver.edgeSide(1.0), 1);
      expect(DirectionResolver.edgeSide(-2), -1);
    });

    test('이미 끝이면 |p| >= 0.8인 동안 유지, 밑으로 오면 끝 아님', () {
      expect(DirectionResolver.edgeSide(-0.85, previousSide: -1), -1);
      expect(DirectionResolver.edgeSide(-0.8, previousSide: -1), -1);
      expect(DirectionResolver.edgeSide(-0.79, previousSide: -1), 0);
      expect(DirectionResolver.edgeSide(0.9, previousSide: 1), 1);
      expect(DirectionResolver.edgeSide(0.79, previousSide: 1), 0);
      // 반대쪽 끝의 유지 기준은 이어받지 않는다.
      expect(DirectionResolver.edgeSide(0.9, previousSide: -1), 0);
      expect(DirectionResolver.edgeSide(null, previousSide: -1), 0);
    });

    test('pos 0.9 근처 흔들림(10/28 서 있음 −1.04±0.24)에서 끝이 유지된다', () {
      var side = 0;
      final seq = <double>[-1.05, -0.92, -0.88, -1.1, -0.95, -0.83, -0.9, -1.2];
      final out = <int>[];
      for (final p in seq) {
        side = DirectionResolver.edgeSide(p, previousSide: side);
        out.add(side);
      }
      expect(out, everyElement(-1));
      // 종전(1.0 하나)이었다면 5번 끝을 벗어났다.
      expect(seq.where((p) => p > -1.0).length, 5);
    });
  });

  group('DirectionResolver T146 보정각 c (A)', () {
    const s = DirectionResolver.edgeSteerDegrees;
    test('끝이면 중앙 쪽으로 20° 옮긴다: 왼쪽 끝 a+20, 오른쪽 끝 a−20', () {
      expect(s, 20.0);
      expect(DirectionResolver.correctedAngle(5, 0), 5);
      expect(DirectionResolver.correctedAngle(null, 0), isNull);
      expect(DirectionResolver.correctedAngle(5, -1), 25);
      expect(DirectionResolver.correctedAngle(-5, 1), -25);
      expect(DirectionResolver.correctedAngle(null, -1), s);
      expect(DirectionResolver.correctedAngle(null, 1), -s);
    });

    test('왼쪽 끝: 직진·바깥쪽은 left(오른쪽으로), 중앙 쪽 8~32°는 front(이미 틀었음)', () {
      String r(double? a, [String? prev]) =>
          DirectionResolver.resolve('front', a, edgeSide: -1, previous: prev);
      expect(r(null), 'left');
      expect(r(0), 'left'); // c = 20
      expect(r(30), 'left'); // 바깥쪽
      expect(r(-7.9), 'left'); // c = 12.1
      expect(r(-8.1), 'front'); // c = 11.9 — 이미 틀었음
      expect(r(-25), 'front'); // 종전 상한 25도 여기서는 front
      expect(r(-31.9), 'front'); // c = -11.9
      expect(r(-32.1), 'right'); // c = -12.1 — 지나치게 돎(종전 25.1부터)
    });

    test('오른쪽 끝은 좌우 대칭', () {
      String r(double? a) =>
          DirectionResolver.resolve('left', a, edgeSide: 1, previous: 'front');
      expect(r(null), 'right');
      expect(r(0), 'right');
      expect(r(8.1), 'front');
      expect(r(31.9), 'front');
      expect(r(32.1), 'left');
    });

    test('끝에서도 T103 떨림 방지(진입 12 / 유지 9)가 c에 걸린다', () {
      // 왼쪽 끝 left 유지: c >= 9 (a >= -11)
      expect(
          DirectionResolver.resolve('left', -10.9,
              edgeSide: -1, previous: 'left'),
          'left');
      expect(
          DirectionResolver.resolve('left', -11.1,
              edgeSide: -1, previous: 'left'),
          'front');
      // 이미 틀었음(front)에서 반대 방향은 c <= -12 (a <= -32)부터
      expect(
          DirectionResolver.resolve('front', -30,
              edgeSide: -1, previous: 'front'),
          'front');
    });

    test('isEdge: 끝 + 중앙 쪽 이탈·front는 끝 문구, 반대 방향은 일반 문구', () {
      expect(DirectionResolver.isEdge('left', -1), isTrue);
      expect(DirectionResolver.isEdge('front', -1), isTrue);
      expect(DirectionResolver.isEdge('right', -1), isFalse);
      expect(DirectionResolver.isEdge('right', 1), isTrue);
      expect(DirectionResolver.isEdge('front', 1), isTrue);
      expect(DirectionResolver.isEdge('left', 1), isFalse);
      expect(DirectionResolver.isEdge('left', 0), isFalse);
      expect(DirectionResolver.isEdge('front', 0), isFalse);
      expect(DirectionResolver.isEdge('none', -1), isFalse);
    });

    test('edgeSteerClass: 왼쪽 끝 left, 오른쪽 끝 right, 그 외 null', () {
      expect(DirectionResolver.edgeSteerClass(-1), 'left');
      expect(DirectionResolver.edgeSteerClass(1), 'right');
      expect(DirectionResolver.edgeSteerClass(0), isNull);
    });

    test('none/approach에는 끝 보정을 적용하지 않는다', () {
      for (final label in ['none', 'approach']) {
        expect(DirectionResolver.resolve(label, 0, edgeSide: -1), label);
        expect(DirectionResolver.resolve(label, null, edgeSide: 1), label);
      }
    });
  });

  // T146 ②: 끝 보정을 |p| 0.5→1.0에서 0→20° 선형(끝 판정과 무관).
  group('DirectionResolver T146 끝 보정 경사 (|p| 0.5→1.0)', () {
    test('상수: 0.5부터 커져 1.0에서 20', () {
      expect(DirectionResolver.edgeRampStartPosition, 0.5);
    });

    test('pos 0.9에서 보정각은 중간값(16°), 0.75에서 10°', () {
      expect(DirectionResolver.edgeShiftDegrees(-0.9, -1), closeTo(16, 1e-9));
      expect(DirectionResolver.edgeShiftDegrees(0.9, 1), closeTo(-16, 1e-9));
      expect(DirectionResolver.edgeShiftDegrees(-0.75, 0), closeTo(10, 1e-9));
      expect(DirectionResolver.correctedAngle(-15, -1, position: -0.9),
          closeTo(1, 1e-9));
    });

    test('|p| <= 0.5는 0, >= 1.0은 20, 위치가 없으면 끝 판정으로 ±20/0', () {
      expect(DirectionResolver.edgeShiftDegrees(0, 0), 0);
      expect(DirectionResolver.edgeShiftDegrees(-0.5, 0), 0);
      expect(DirectionResolver.edgeShiftDegrees(-1.0, -1), 20);
      expect(DirectionResolver.edgeShiftDegrees(1.7, 1), -20);
      expect(DirectionResolver.edgeShiftDegrees(null, -1), 20);
      expect(DirectionResolver.edgeShiftDegrees(null, 0), 0);
    });

    test('이미 틀었음(중앙 쪽 15°)인 채 끝 경계(0.8)를 넘어도 반대 방향 R0가 안 나온다', () {
      // 왼쪽 끝 −1.1에서 중앙 쪽으로 15° 틀고(a = −15) 중앙 쪽으로 걸어간다.
      // T160: 끝을 벗어나면 문턱이 8.5라 −0.62(c = −10.2)에서는 right가 나온다
      // (종전 12면 front) — 그래서 −0.7까지만 본다. 아래 별도 확인.
      var side = 0;
      var label = 'front';
      final out = <String>[];
      for (final p in <double>[-1.1, -0.95, -0.85, -0.79, -0.7]) {
        side = DirectionResolver.edgeSide(p, previousSide: side);
        label = DirectionResolver.resolve('front', -15,
            edgeSide: side, position: p, previous: label);
        out.add(label);
      }
      expect(out, everyElement('front'));
      // 계단(위치 없이 끝 판정만)이면 끝을 벗어나는 −0.79에서 바로 right(왼쪽으로)였다.
      expect(DirectionResolver.resolve('front', -15, edgeSide: 0), 'right');
      // T160: 끝 아님 + c = −10.2(<= −8.5)면 right.
      expect(
          DirectionResolver.resolve('front', -15,
              edgeSide: 0, position: -0.62, previous: 'front'),
          'right');
    });

    test('중앙 가까이(0.5 이하)까지 그 각도로 오면 그때 직진 쪽 안내(right)', () {
      expect(
          DirectionResolver.resolve('front', -15,
              edgeSide: 0, position: -0.5, previous: 'front'),
          'right');
    });
  });

  group('DirectionResolver.deviationLevel (T160: 약 0 / 강 2, 경계 29, 내려갈 때 26)', () {
    int lv(double? c, [int? prev]) =>
        DirectionResolver.deviationLevel(c, previous: prev);

    test('상수: 29 / 29 / 떨림 방지 3', () {
      expect(DirectionResolver.level1Degrees, 29.0);
      expect(DirectionResolver.level2Degrees, 29.0);
      expect(DirectionResolver.levelHysteresisDegrees, 3.0);
    });

    test('올라갈 때는 29에서 바로 2(강)', () {
      expect(lv(null), 0);
      expect(lv(8.5), 0);
      expect(lv(28.9), 0);
      expect(lv(29), 2);
      expect(lv(-29), 2);
      expect(lv(-45), 2);
      expect(lv(31, 0), 2);
    });

    test('단계 1은 나오지 않는다(어떤 각도·직전 단계에서도)', () {
      for (var c = -60.0; c <= 60.0; c += 0.5) {
        for (final prev in <int?>[null, 0, 2]) {
          expect(lv(c, prev), isNot(1), reason: 'c=$c prev=$prev');
        }
      }
    });

    test('내려갈 때는 26 밑으로 와야 2 → 0으로 바로', () {
      expect(lv(26, 2), 2);
      expect(lv(-26, 2), 2);
      expect(lv(25.9, 2), 0);
      expect(lv(25.9, 0), 0);
      expect(lv(10, 2), 0);
    });

    // 사용자 기대: 크게 이탈한 뒤 직진 쪽으로 돌면 박자가 느려진다(T160: 2 → 0).
    test('큰 이탈 → 직진 쪽으로 돌면 2→0→직진으로 내려간다', () {
      int? prev;
      String label = 'left';
      final levels = <int>[];
      final labels = <String>[];
      for (final a in <double>[40, 32, 27, 24, 16, 10, 6, 5]) {
        label = DirectionResolver.resolve('left', a, previous: label);
        labels.add(label);
        if (label == 'left') {
          prev = DirectionResolver.deviationLevel(a, previous: prev);
          levels.add(prev);
        }
      }
      expect(levels, [2, 2, 2, 0, 0, 0, 0]);
      expect(labels.last, 'front');
    });

    test('끝에서 중앙 쪽으로 돌면 2→0→이미 틀었음으로 내려간다 (D8·D10 유형, T160)', () {
      // 왼쪽 끝, 바깥쪽 +15°에서 중앙 쪽으로 −13°까지 돈다.
      int? prev;
      String label = 'front';
      final trace = <String>[];
      for (final a in <double>[15, 8, 2, -2, -6, -10, -13]) {
        label = DirectionResolver.resolve('left', a,
            edgeSide: -1, previous: label);
        final c = DirectionResolver.correctedAngle(a, -1);
        if (label == 'left') {
          prev = DirectionResolver.deviationLevel(c, previous: prev);
          trace.add('L$prev');
        } else {
          prev = null;
          trace.add(DirectionResolver.isEdge(label, -1) ? 'TL' : label);
        }
      }
      expect(trace, ['L2', 'L2', 'L0', 'L0', 'L0', 'L0', 'TL']); // c 35, 28(>=26), 22…
    });

    test('강 경계(29) 근처에서 ±3° 흔들려도 단계가 깜빡이지 않는다', () {
      // T160: 경계가 29 하나라 떨림 방지가 없으면 0/2가 번갈아 나온다.
      final cs = <double>[30, 28, 27.2, 29.6, 26.5, 28.8, 30.4, 27.9, 26.1, 29.2];
      int? prev;
      final levels = <int>[];
      for (final c in cs) {
        prev = DirectionResolver.deviationLevel(c, previous: prev);
        levels.add(prev);
      }
      expect(levels, everyElement(2));
      // 떨림 방지 없이(직전 단계 없이) 매번 정하면 6번 바뀐다.
      final naive = cs.map((c) => DirectionResolver.deviationLevel(c)).toList();
      var changes = 0;
      for (var i = 1; i < naive.length; i++) {
        if (naive[i] != naive[i - 1]) changes++;
      }
      expect(changes, 6);
    });

    test('서 있지 않은 아래쪽 시작(18)에서는 20을 넘을 때까지 0을 유지', () {
      int? prev;
      final levels = <int>[];
      for (final c in <double>[18, 19.5, 18.8, 19.9]) {
        prev = DirectionResolver.deviationLevel(c, previous: prev);
        levels.add(prev);
      }
      expect(levels, everyElement(0));
    });
  });

  group('DirectionResolver T160 B: 끝에서는 종전 12 / 9 (32° · 8~32° · 11°)', () {
    String r(double a, {String? prev, int side = -1}) =>
        DirectionResolver.resolve('left', a,
            edgeSide: side, previous: prev ?? 'front');

    test('상수: 끝 진입 12 / 유지 9, 끝 아님 8.5 / 5.5', () {
      expect(DirectionResolver.edgeDeviationAngleDegrees, 12.0);
      expect(DirectionResolver.edgeRecoverAngleDegrees, 9.0);
      expect(DirectionResolver.deviationAngleDegrees, 8.5);
      expect(DirectionResolver.recoverAngleDegrees, 5.5);
    });

    test('반대 방향 안내는 중앙 쪽 32°부터 (왼쪽 끝 a <= −32)', () {
      expect(r(-31.9), 'front');
      expect(r(-32), 'right');
      expect(r(31.9, side: 1), 'front');
      expect(r(32, side: 1), 'left');
    });

    test('이미 틀었음은 중앙 쪽 8~32° (직전 front)', () {
      expect(r(-7.9), 'left'); // c = 12.1
      expect(r(-8.1), 'front'); // c = 11.9
      expect(r(-20), 'front');
      expect(r(-31.9), 'front');
      expect(r(8.1, side: 1), 'front');
      expect(r(7.9, side: 1), 'right');
    });

    test('끝 유도(left)에서 이미 틀었음으로 넘어가는 지점은 중앙 쪽 11°', () {
      expect(r(-10.9, prev: 'left'), 'left'); // c = 9.1 >= 9
      expect(r(-11.1, prev: 'left'), 'front'); // c = 8.9
      expect(r(10.9, prev: 'right', side: 1), 'right');
      expect(r(11.1, prev: 'right', side: 1), 'front');
    });

    test('끝이 아니면 8.5 / 5.5 (같은 c라도 결과가 다르다)', () {
      expect(DirectionResolver.resolve('front', 10, previous: 'front'), 'left');
      expect(DirectionResolver.resolve('left', 6, previous: 'left'), 'left');
      expect(DirectionResolver.resolve('left', -10, edgeSide: -1), 'front');
    });
  });

  group('DirectionResolver T158 끝 직진 ((a2)+(e))', () {
    String r(double? a, int side, double? p, [String? prev]) =>
        DirectionResolver.resolve('front', a,
            edgeSide: side, position: p, previous: prev);
    int lv(double? a, int side, double? p, [int? prev]) =>
        DirectionResolver.deviationLevel(
            DirectionResolver.levelAngle(a, side, position: p),
            previous: prev);

    test('상수: 직진 9°, 깊은 끝 1.5', () {
      expect(DirectionResolver.edgeStraightDegrees, 9.0);
      expect(DirectionResolver.deepEdgePosition, 1.5);
    });

    test('1행: 끝 + |p| < 1.5 + 직진 → front(+ 끝)', () {
      expect(r(0, -1, -1.2), 'front'); // 종전 c = 20 → left
      expect(r(8.9, -1, -1.2), 'front');
      expect(r(-8.9, -1, -1.2), 'front');
      expect(r(0, -1, -1.2, 'left'), 'front'); // 직전 left여도
      expect(r(0, -1, -0.9, 'left'), 'front'); // 끝 유지 구간(0.8~1.0)
      expect(DirectionResolver.isEdge('front', -1), isTrue);
      expect(DirectionResolver.levelAngle(0, -1, position: -1.2), 20);
    });

    test('2행: 끝 + |p| >= 1.5 + 직진 → 중앙 쪽 명령, 단계 0 고정', () {
      expect(r(0, -1, -1.8), 'left');
      expect(r(8.9, -1, -2.0), 'left'); // c = 28.9 → 종전 단계 1(T160 경계 29 바로 밑)
      expect(DirectionResolver.isEdge('left', -1), isTrue);
      expect(lv(0, -1, -1.8), 0);
      expect(lv(8.9, -1, -2.0), 0);
      expect(lv(8.9, -1, -2.0, 2), 0); // 이전 단계 2여도 0
      expect(DirectionResolver.levelAngle(8.9, -1, position: -2.0), 12.0);
    });

    test('3행: 끝 + 직진 아님 → T146 그대로', () {
      expect(r(9, -1, -1.2), 'left'); // 바깥쪽 9° (c = 29)
      expect(lv(9, -1, -1.2), 2); // T160: c = 29 → 강
      expect(lv(15, -1, -1.8), 2); // 깊은 끝도 직진 아니면 단계 그대로 (c = 35)
      expect(r(-9, -1, -1.2), 'front'); // 중앙 쪽 9° (c = 11, 이미 틀었음)
      expect(r(-40, -1, -1.2), 'right'); // 지나치게 돎
      expect(r(null, -1, -1.2), 'left'); // 각도 없음 = 직진 아님
      expect(lv(null, -1, -1.8), 0); // c = 20 (T160: 29 밑이라 약)
    });

    test('끝 + 각도 없음 = 직진 아님 → T146 그대로(중앙 쪽 명령)', () {
      for (final p in <double>[-0.9, -1.2, -1.49, -1.5, -2.0]) {
        expect(r(null, -1, p), 'left', reason: 'p=$p');
        expect(DirectionResolver.levelAngle(null, -1, position: p),
            DirectionResolver.correctedAngle(null, -1, position: p),
            reason: 'p=$p');
      }
      expect(r(null, 1, 1.2), 'right');
      expect(r(null, 1, 1.8), 'right');
      expect(DirectionResolver.isEdgeStraight(null, -1), isFalse);
    });

    test('4행: 끝 아님 → 그대로', () {
      expect(r(0, 0, -0.7), 'front');
      expect(r(12, 0, -0.3), 'left');
      expect(DirectionResolver.levelAngle(5, 0, position: -0.7),
          DirectionResolver.correctedAngle(5, 0, position: -0.7));
    });

    test('|p| 1.49 / 1.5 경계', () {
      expect(r(0, -1, -1.49), 'front');
      expect(r(0, -1, -1.5), 'left');
      expect(lv(0, -1, -1.5), 0);
      expect(r(0, 1, 1.49), 'front');
      expect(r(0, 1, 1.5), 'right');
      expect(lv(0, 1, 1.5), 0);
    });

    test('좌우 대칭', () {
      for (final (a, p) in <(double, double)>[
        (0, 1.2), (5, 1.2), (8.9, 1.49), (0, 1.5), (5, 1.8), (8.9, 2.0),
        (9, 1.2), (15, 1.8), (-40, 1.2),
      ]) {
        final lr = r(a, -1, -p);
        final rr = r(-a, 1, p);
        final mirror = {'left': 'right', 'right': 'left', 'front': 'front'};
        expect(rr, mirror[lr], reason: 'a=$a p=$p');
        expect(DirectionResolver.levelAngle(-a, 1, position: p),
            -DirectionResolver.levelAngle(a, -1, position: -p)!,
            reason: 'a=$a p=$p');
      }
    });
  });

  group('StillOppositeDelay (T146 C: 서 있을 때 반대 방향 1.5초)', () {
    final t0 = DateTime(2026, 10, 28, 16, 52, 41);
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

    test('상수: 1.5초, 서 있을 때 평활 0.3', () {
      expect(DirectionResolver.stillOppositeHold,
          const Duration(milliseconds: 1500));
      expect(DirectionResolver.stillSmoothingFactor, 0.3);
    });

    test('서 있으면 반대 방향은 1.5초 이어져야 바뀐다 (그 전에는 직전 상태)', () {
      final d = StillOppositeDelay();
      expect(d.apply('left', previous: 'front', still: true, now: t0).label,
          'left');
      var r = d.apply('right', previous: 'left', still: true, now: at(300));
      expect(r.held, isTrue);
      expect(r.label, 'left');
      r = d.apply('right', previous: 'left', still: true, now: at(1700));
      expect(r.held, isTrue);
      r = d.apply('right', previous: 'left', still: true, now: at(1800));
      expect(r.held, isFalse);
      expect(r.label, 'right');
    });

    test('걷는 중이면 반대 방향도 바로 바뀐다', () {
      final d = StillOppositeDelay();
      d.apply('left', previous: 'front', still: false, now: t0);
      final r = d.apply('right', previous: 'left', still: false, now: at(100));
      expect(r.held, isFalse);
      expect(r.label, 'right');
    });

    test('16:52 재현: 서서 left ↔ right가 1초 안에 번갈아 나오면 반대 안내가 나가지 않는다', () {
      final d = StillOppositeDelay();
      var prev = 'front';
      final out = <String>[];
      final seq = ['left', 'right', 'left', 'right', 'front', 'right', 'left'];
      for (var i = 0; i < seq.length; i++) {
        final r = d.apply(seq[i], previous: prev, still: true, now: at(i * 400));
        prev = r.label;
        out.add(r.label);
      }
      expect(out, ['left', 'left', 'left', 'left', 'front', 'front', 'left']);
    });

    test('front·같은 방향이 끼면 이어짐 시계를 처음부터', () {
      final d = StillOppositeDelay();
      d.apply('left', previous: 'front', still: true, now: t0);
      d.apply('right', previous: 'left', still: true, now: at(100));
      d.apply('front', previous: 'left', still: true, now: at(1000));
      final r = d.apply('right', previous: 'front', still: true, now: at(1700));
      expect(r.held, isTrue, reason: '1.6초 전 시작이지만 front에서 끊겼다');
      expect(r.label, 'front');
    });

    test('위를 벗어나면 기억을 지운다 — 다음 이탈은 첫 이탈', () {
      final d = StillOppositeDelay();
      d.apply('left', previous: 'front', still: true, now: t0);
      d.apply('none', previous: 'left', still: true, now: at(100));
      final r = d.apply('right', previous: 'none', still: true, now: at(200));
      expect(r.held, isFalse);
    });
  });

  group('DirectionResolver 경계 떨림 방지 (T103, T160: 들어갈 때 8.5 / 유지 5.5)', () {
    const r = DirectionResolver.recoverAngleDegrees;
    test('상수: 유지 5.5도 < 진입 8.5도 (간격 3)', () {
      expect(r, 5.5);
      expect(DirectionResolver.deviationAngleDegrees - r, 3.0);
    });

    test('이미 left면 +5.5 이상인 동안 left 유지, 밑으로 내려가면 front', () {
      for (final a in <double>[5.5, 7, 8.4]) {
        expect(DirectionResolver.resolve('left', a, previous: 'left'), 'left',
            reason: '$a');
      }
      expect(DirectionResolver.resolve('left', 5.4, previous: 'left'),
          'front');
    });

    test('이미 right면 -5.5 이하인 동안 right 유지', () {
      expect(DirectionResolver.resolve('right', -7, previous: 'right'),
          'right');
      expect(DirectionResolver.resolve('right', -5.4, previous: 'right'),
          'front');
    });

    test('직전이 front면 5.5~8.5는 front (들어갈 때는 8.5)', () {
      expect(DirectionResolver.resolve('front', 7, previous: 'front'),
          'front');
      expect(DirectionResolver.resolve('front', -7, previous: 'front'),
          'front');
      expect(DirectionResolver.resolve('front', 8.5, previous: 'front'),
          'left');
    });

    test('반대 방향으로 기준을 넘으면 바로 바뀐다', () {
      expect(DirectionResolver.resolve('left', -12, previous: 'left'),
          'right');
    });

    test('T146: 끝 보정 뒤 떨림 방지를 건다', () {
      // 왼쪽 끝 + 중앙 쪽으로 12° 틂 -> c = 8. 직전이 right여도 front.
      expect(
          DirectionResolver.resolve('right', -12,
              edgeSide: -1, previous: 'right'),
          'front');
    });
  });

  // T130 D: 끝↔각도가 1초 안에 반대로 뒤집히면 직전 상태 유지.
  group('EdgeAngleFlipGuard (T130)', () {
    final t0 = DateTime(2026, 10, 24, 19, 28, 22);
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

    test('첫 경고는 그대로', () {
      final g = EdgeAngleFlipGuard(enabled: true);
      final d = g.apply('left', previous: 'front', angleDegrees: 20, now: t0);
      expect(d.label, 'left');
      expect(d.held, isFalse);
    });

    test('19:28 재현: 각도 left 뒤 0.25초에 끝 right → 막고 직전 상태(front) 유지', () {
      final g = EdgeAngleFlipGuard(enabled: true);
      g.apply('left', previous: 'front', angleDegrees: 21, now: t0);
      g.apply('front', previous: 'left', angleDegrees: 6, now: at(1295));
      final d = g.apply('right',
          previous: 'front', position: 1.01, angleDegrees: 6, now: at(1550));
      expect(d.held, isTrue);
      expect(d.label, 'front');
      expect(d.from, 'left');
      expect(d.source, 'edge');
      expect(d.sinceMs, 255);
    });

    test('반대 방향 직접 전환(left → right)도 막으면 left 유지', () {
      final g = EdgeAngleFlipGuard(enabled: true);
      g.apply('left', previous: 'front', angleDegrees: 20, now: t0);
      final d = g.apply('right',
          previous: 'left', position: 1.2, angleDegrees: 5, now: at(500));
      expect(d.held, isTrue);
      expect(d.label, 'left');
    });

    test('1초가 지나면 뒤집는다', () {
      final g = EdgeAngleFlipGuard(enabled: true);
      g.apply('left', previous: 'front', angleDegrees: 20, now: t0);
      g.apply('front', previous: 'left', angleDegrees: 5, now: at(200));
      final d = g.apply('right',
          previous: 'front', position: 1.2, angleDegrees: 5, now: at(1200));
      expect(d.held, isFalse);
      expect(d.label, 'right');
    });

    test('같은 출처(각도→각도)의 반대 전환은 그대로 (실제로 급히 튼 경우)', () {
      final g = EdgeAngleFlipGuard(enabled: true);
      g.apply('left', previous: 'front', angleDegrees: 20, now: t0);
      final d =
          g.apply('right', previous: 'left', angleDegrees: -20, now: at(300));
      expect(d.held, isFalse);
      expect(d.label, 'right');
    });

    test('같은 방향 경고는 출처가 바뀌어도 그대로', () {
      final g = EdgeAngleFlipGuard(enabled: true);
      g.apply('right', previous: 'front', angleDegrees: -20, now: t0);
      final d = g.apply('right',
          previous: 'right', position: 1.3, angleDegrees: 5, now: at(300));
      expect(d.held, isFalse);
      expect(d.label, 'right');
    });

    test('막은 판정은 기억을 갱신하지 않는다 — 1초 넘게 이어지지 않음', () {
      final g = EdgeAngleFlipGuard(enabled: true);
      g.apply('left', previous: 'front', angleDegrees: 20, now: t0);
      expect(
          g
              .apply('right',
                  previous: 'left', position: 1.2, angleDegrees: 5, now: at(600))
              .held,
          isTrue);
      expect(
          g
              .apply('right',
                  previous: 'left', position: 1.2, angleDegrees: 5, now: at(1000))
              .held,
          isFalse);
    });

    test('위를 벗어나면(none/approach/crossed) 기억을 지운다 — 다음 경고는 첫 경고', () {
      final g = EdgeAngleFlipGuard(enabled: true);
      g.apply('left', previous: 'front', angleDegrees: 20, now: t0);
      expect(g.apply('none', previous: 'left', now: at(100)).label, 'none');
      final d = g.apply('right',
          previous: 'front', position: 1.2, angleDegrees: 5, now: at(300));
      expect(d.held, isFalse);
    });

    test('직전 상태가 위가 아니면 막지 않는다', () {
      final g = EdgeAngleFlipGuard(enabled: true);
      g.apply('left', previous: 'front', angleDegrees: 20, now: t0);
      final d = g.apply('right',
          previous: 'hold', position: 1.2, angleDegrees: 5, now: at(300));
      expect(d.held, isFalse);
    });

    // T132 ③: 기본으로 꺼져 있다 — 같은 19:28 재현도 막지 않는다.
    test('T132: 기본값은 꺼짐 — 막지 않고 받은 판정 그대로', () {
      expect(EdgeAngleFlipGuard.enabledByDefault, isFalse);
      final g = EdgeAngleFlipGuard();
      expect(g.enabled, isFalse);
      g.apply('left', previous: 'front', angleDegrees: 21, now: t0);
      g.apply('front', previous: 'left', angleDegrees: 6, now: at(1295));
      final d = g.apply('right',
          previous: 'front', position: 1.01, angleDegrees: 6, now: at(1550));
      expect(d.held, isFalse);
      expect(d.label, 'right');
    });
  });
}
