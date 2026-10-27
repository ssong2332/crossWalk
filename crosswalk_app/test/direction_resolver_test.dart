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

    test('|각도| < 12 이면(직전 이탈 아님) 분류기가 뭐라 했든 front', () {
      // 실기기 #29: 직진인데 "오른쪽으로 틀어짐", 각도 2 -> front.
      // T103: 기준 15 -> 12.
      expect(t, 12.0);
      for (final label in ['front', 'left', 'right']) {
        for (final a in <double>[0, 2, -2, 8.9, -8.9, 11.9, -11.9]) {
          expect(DirectionResolver.resolve(label, a), 'front',
              reason: '$label/$a');
        }
      }
    });

    test('각도 >= +12 이면 left(오른쪽으로 가라), <= -12 이면 right', () {
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
  group('DirectionResolver T98 위치(끝) 규칙', () {
    const e = DirectionResolver.edgePosition;
    const s = DirectionResolver.edgeSteerDegrees;

    test('edgeSteerAngle: 왼쪽 끝 +20, 오른쪽 끝 -20, 그 외 null', () {
      expect(DirectionResolver.edgeSteerAngle(null, 0), isNull);
      expect(DirectionResolver.edgeSteerAngle(0, 0), isNull);
      expect(DirectionResolver.edgeSteerAngle(-0.99, 0), isNull);
      expect(DirectionResolver.edgeSteerAngle(0.99, 0), isNull);
      expect(DirectionResolver.edgeSteerAngle(-e, null), s);
      expect(DirectionResolver.edgeSteerAngle(-2, 0), s);
      expect(DirectionResolver.edgeSteerAngle(e, null), -s);
      expect(DirectionResolver.edgeSteerAngle(2, 0), -s);
    });

    test('T100: 끝인데 각도가 이미 중앙 쪽 ±기준 이상이면 0(직진 유지)', () {
      const t = DirectionResolver.deviationAngleDegrees;
      // 왼쪽 끝: 오른쪽으로 가라(+). 각도가 -기준 이하면 이미 오른쪽으로 튼 것.
      // T103: 기준이 15 -> 12로 바뀌며 이 판정도 함께 12를 쓴다.
      expect(DirectionResolver.edgeSteerAngle(-2, -t), 0);
      // T137: 상한 25° 안쪽 값(이전 -30은 이제 상한 초과).
      expect(DirectionResolver.edgeSteerAngle(-2, -20), 0);
      expect(DirectionResolver.edgeSteerAngle(-2, -(t - 0.1)), s);
      expect(DirectionResolver.edgeSteerAngle(-2, 30), s); // 바깥쪽이면 여전히 유도
      // 오른쪽 끝: 대칭.
      expect(DirectionResolver.edgeSteerAngle(2, t), 0);
      expect(DirectionResolver.edgeSteerAngle(2, 20), 0);
      expect(DirectionResolver.edgeSteerAngle(2, t - 0.1), -s);
      expect(DirectionResolver.edgeSteerAngle(2, -30), -s);
    });

    test('왼쪽 끝이면 각도 없음·직진·바깥쪽 이탈 모두 left(오른쪽으로 가라)', () {
      for (final label in ['front', 'left', 'right']) {
        for (final a in <double?>[null, 0, 14, 40]) {
          expect(DirectionResolver.resolve(label, a, position: -1.5), 'left',
              reason: '$label/$a');
        }
      }
    });

    test('오른쪽 끝이면 각도 없음·직진·바깥쪽 이탈 모두 right(왼쪽으로 가라)', () {
      for (final label in ['front', 'left', 'right']) {
        for (final a in <double?>[null, 0, -14, -40]) {
          expect(DirectionResolver.resolve(label, a, position: 1.5), 'right',
              reason: '$label/$a');
        }
      }
    });

    test('T100: 끝에서 이미 중앙 쪽으로 틀었으면 front(유지) — 실기기 #3', () {
      for (final label in ['front', 'left', 'right']) {
        // T137: 상한 25° 안쪽 값(이전 ±30은 이제 상한 초과).
        expect(DirectionResolver.resolve(label, -20, position: -1.3), 'front',
            reason: label);
        expect(DirectionResolver.resolve(label, 20, position: 1.3), 'front',
            reason: label);
      }
    });

    test('끝이 아니면(|p|<1) 기존 각도 표 그대로', () {
      for (final p in <double?>[null, 0, 0.9, -0.9]) {
        expect(DirectionResolver.resolve('left', 0, position: p), 'front');
        expect(DirectionResolver.resolve('front', 40, position: p), 'left');
        expect(DirectionResolver.resolve('front', -40, position: p), 'right');
        expect(DirectionResolver.resolve('right', null, position: p), 'right');
      }
    });

    test('none/approach에는 위치 규칙을 적용하지 않는다', () {
      for (final label in ['none', 'approach']) {
        expect(DirectionResolver.resolve(label, 40, position: -2), label);
        expect(DirectionResolver.resolve(label, null, position: 2), label);
      }
    });
  });

  // T137: 끝 규칙 '이미 틀었음'에 상한 25° (10/26 밤 ⑥(a), 사용자 승인 1-a).
  group('DirectionResolver T137 끝 규칙 각도 상한', () {
    const m = DirectionResolver.edgeTurnedMaxDegrees;
    const s = DirectionResolver.edgeSteerDegrees;

    test('상한은 25°', () {
      expect(m, 25.0);
    });

    test('중앙 쪽으로 25° 이하면 그대로(front), 넘으면 끝 규칙 미적용(null)', () {
      // 왼쪽 끝: 중앙 쪽 = 음수.
      expect(DirectionResolver.edgeSteerAngle(-1.5, -m), 0);
      expect(DirectionResolver.edgeSteerAngle(-1.5, -(m + 0.1)), isNull);
      expect(DirectionResolver.edgeSteerAngle(-1.5, -42), isNull);
      // 오른쪽 끝: 대칭.
      expect(DirectionResolver.edgeSteerAngle(1.5, m), 0);
      expect(DirectionResolver.edgeSteerAngle(1.5, m + 0.1), isNull);
      expect(DirectionResolver.edgeSteerAngle(1.5, 42), isNull);
      // 바깥쪽으로 크게 틀었으면 상한과 무관하게 중앙 쪽으로 유도(종전대로).
      expect(DirectionResolver.edgeSteerAngle(-1.5, 42), s);
      expect(DirectionResolver.edgeSteerAngle(1.5, -42), -s);
    });

    test('resolve: 25° 이하면 그대로, 25° 초과면 이탈 유지', () {
      for (final label in ['front', 'left', 'right']) {
        // 왼쪽 끝, 오른쪽으로 크게 틂 -> 각도 표: 왼쪽으로 가라(right).
        expect(DirectionResolver.resolve(label, -25, position: -1.2), 'front',
            reason: label);
        expect(DirectionResolver.resolve(label, -32, position: -1.2), 'right',
            reason: label);
        // 오른쪽 끝, 왼쪽으로 크게 틂 -> 각도 표: 오른쪽으로 가라(left).
        expect(DirectionResolver.resolve(label, 25, position: 1.2), 'front',
            reason: label);
        expect(DirectionResolver.resolve(label, 32, position: 1.2), 'left',
            reason: label);
      }
    });

    test('25° 초과는 끝 안내가 아니다(isEdge false — 각도 이탈 안내)', () {
      expect(DirectionResolver.isEdge('right', -1.2, -32), isFalse);
      expect(DirectionResolver.isEdge('front', -1.2, -25), isTrue);
    });
  });

  // T143: '이미 틀었음' 상한 25/21·하한 12/9 떨림 방지 (10/27 낮 12:27·12:28).
  group('DirectionResolver T143 끝 떨림 방지', () {
    String res(double a, double p, String prev, bool prevEdge) =>
        DirectionResolver.resolve('front', a,
            position: p, previous: prev, previousAtEdge: prevEdge);

    test('상수: 다시 들어옴 21 < 상한 25, 유지 하한 9 < 진입 12', () {
      expect(DirectionResolver.edgeTurnedMaxDegrees, 25.0);
      expect(DirectionResolver.edgeTurnedReenterDegrees, 21.0);
      expect(DirectionResolver.edgeTurnedKeepDegrees, 9.0);
      expect(DirectionResolver.deviationAngleDegrees, 12.0);
    });

    test('상한: 이미 틀었음이면 25까지 유지, 넘으면 이탈', () {
      expect(res(-25, -1.5, 'front', true), 'front');
      expect(res(-25.1, -1.5, 'front', true), 'right');
      expect(res(25, 1.5, 'front', true), 'front');
      expect(res(25.1, 1.5, 'front', true), 'left');
    });

    test('상한: 넘어 이탈한 뒤에는 21 이하로 와야 다시 이미 틀었음', () {
      // 왼쪽 끝 + right(상한 넘어 이탈).
      expect(res(-24, -1.5, 'right', false), 'right');
      expect(res(-21.1, -1.5, 'right', false), 'right');
      expect(res(-21, -1.5, 'right', false), 'front');
      // 오른쪽 끝 + left.
      expect(res(24, 1.5, 'left', false), 'left');
      expect(res(21, 1.5, 'left', false), 'front');
    });

    test('12:27 재현: 25 근처 오르내림에 번갈아 바뀌지 않는다', () {
      // 왼쪽 끝, 각도 -23.8 → -26.0 → -24.7 → -26.2 → -23.0 (smooth 근사).
      var prev = 'front';
      var prevEdge = true;
      final seen = <String>[];
      for (final a in [-23.8, -26.0, -24.7, -26.2, -23.0, -20.5]) {
        final next = res(a, -1.7, prev, prevEdge);
        prevEdge = DirectionResolver.isEdge(next, -1.7, a,
            previous: prev, previousAtEdge: prevEdge);
        prev = next;
        seen.add(next);
      }
      // 26.0에서 한 번 나가고, 21 이하(-20.5)가 돼서야 돌아온다(전환 2번).
      expect(seen, ['front', 'right', 'right', 'right', 'right', 'front']);
    });

    test('하한: 끝 유도에서는 12부터 이미 틀었음, 이미 틀었음이면 9까지 유지', () {
      // 왼쪽 끝, 직전 끝 유도(left + 끝).
      expect(res(-11.9, -1.2, 'left', true), 'left');
      expect(res(-12, -1.2, 'left', true), 'front');
      // 직전 이미 틀었음.
      expect(res(-11.3, -1.2, 'front', true), 'front', reason: '12:28:19.5');
      expect(res(-9, -1.2, 'front', true), 'front');
      expect(res(-8.9, -1.2, 'front', true), 'left');
      // 오른쪽 끝 대칭.
      expect(res(10, 1.2, 'front', true), 'front');
      expect(res(10, 1.2, 'right', true), 'right');
    });

    test('일반 직진(끝 아님)에서 끝으로 오면 하한은 12 그대로', () {
      expect(res(-10, -1.2, 'front', false), 'left');
      expect(res(-12, -1.2, 'front', false), 'front');
    });

    test('직전 상태를 안 주면 T137 동작 그대로(12~25)', () {
      expect(DirectionResolver.edgeSteerAngle(-1.5, -12), 0);
      expect(DirectionResolver.edgeSteerAngle(-1.5, -11), 20);
      expect(DirectionResolver.edgeSteerAngle(-1.5, -25), 0);
      expect(DirectionResolver.edgeSteerAngle(-1.5, -26), isNull);
    });

    test('edgeSteerClass: 왼쪽 끝 left, 오른쪽 끝 right, 그 외 null', () {
      expect(DirectionResolver.edgeSteerClass(-1.0), 'left');
      expect(DirectionResolver.edgeSteerClass(1.3), 'right');
      expect(DirectionResolver.edgeSteerClass(0.9), isNull);
      expect(DirectionResolver.edgeSteerClass(null), isNull);
    });
  });

  group('DirectionResolver.isEdge (T102)', () {
    test('끝 규칙에서 나온 left/right와 이미 튼 front는 끝', () {
      expect(DirectionResolver.isEdge('left', -1.2, -3), isTrue); // 실기기 #3
      expect(DirectionResolver.isEdge('right', 1.2, 3), isTrue);
      expect(DirectionResolver.isEdge('front', -1.4, -25), isTrue); // 실기기 #4
      expect(DirectionResolver.isEdge('front', 1.4, 25), isTrue);
    });

    test('끝이 아니거나 위치가 없으면 끝이 아니다', () {
      for (final p in <double?>[null, 0, 0.9, -0.9]) {
        expect(DirectionResolver.isEdge('left', p, 40), isFalse);
        expect(DirectionResolver.isEdge('front', p, 0), isFalse);
      }
    });

    test('none/approach는 옛 위치값이 끝이어도 끝이 아니다', () {
      for (final label in ['none', 'approach']) {
        expect(DirectionResolver.isEdge(label, -2, 0), isFalse);
      }
    });
  });

  group('DirectionResolver 경계 떨림 방지 (T103, 들어갈 때 12 / 유지 9)', () {
    const r = DirectionResolver.recoverAngleDegrees;
    test('상수: 유지 9도 < 진입 12도', () {
      expect(r, 9.0);
      expect(r, lessThan(DirectionResolver.deviationAngleDegrees));
    });

    test('이미 left면 +9 이상인 동안 left 유지, 밑으로 내려가면 front', () {
      for (final a in <double>[9, 10, 11.9]) {
        expect(DirectionResolver.resolve('left', a, previous: 'left'), 'left',
            reason: '$a');
      }
      expect(DirectionResolver.resolve('left', 8.9, previous: 'left'),
          'front');
    });

    test('이미 right면 -9 이하인 동안 right 유지', () {
      expect(DirectionResolver.resolve('right', -10, previous: 'right'),
          'right');
      expect(DirectionResolver.resolve('right', -8.9, previous: 'right'),
          'front');
    });

    test('직전이 front면 9~12는 front (들어갈 때는 12)', () {
      expect(DirectionResolver.resolve('front', 10, previous: 'front'),
          'front');
      expect(DirectionResolver.resolve('front', -10, previous: 'front'),
          'front');
    });

    test('반대 방향으로 기준을 넘으면 바로 바뀐다', () {
      expect(DirectionResolver.resolve('left', -12, previous: 'left'),
          'right');
    });

    test('끝 규칙이 떨림 방지보다 먼저다', () {
      // 왼쪽 끝 + 이미 오른쪽으로 크게 틂(-12) -> 직전이 right여도 front.
      expect(
          DirectionResolver.resolve('right', -12,
              position: -1.5, previous: 'right'),
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
