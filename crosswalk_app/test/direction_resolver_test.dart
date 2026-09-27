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
      expect(DirectionResolver.edgeSteerAngle(-2, -30), 0);
      expect(DirectionResolver.edgeSteerAngle(-2, -(t - 0.1)), s);
      expect(DirectionResolver.edgeSteerAngle(-2, 30), s); // 바깥쪽이면 여전히 유도
      // 오른쪽 끝: 대칭.
      expect(DirectionResolver.edgeSteerAngle(2, t), 0);
      expect(DirectionResolver.edgeSteerAngle(2, 30), 0);
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
        expect(DirectionResolver.resolve(label, -30, position: -1.3), 'front',
            reason: label);
        expect(DirectionResolver.resolve(label, 30, position: 1.3), 'front',
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
}
