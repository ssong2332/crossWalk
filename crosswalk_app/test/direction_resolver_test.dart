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

    test('|각도| < 15 이면 분류기가 뭐라 했든 front', () {
      // 실기기 #29: 직진인데 "오른쪽으로 틀어짐", 각도 2 -> front.
      for (final label in ['front', 'left', 'right']) {
        for (final a in <double>[0, 2, -2, 10, -10, 14.9, -14.9]) {
          expect(DirectionResolver.resolve(label, a), 'front',
              reason: '$label/$a');
        }
      }
    });

    test('각도 >= +15 이면 left(오른쪽으로 가라), <= -15 이면 right', () {
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
      expect(DirectionResolver.edgeSteerAngle(null), isNull);
      expect(DirectionResolver.edgeSteerAngle(0), isNull);
      expect(DirectionResolver.edgeSteerAngle(-0.99), isNull);
      expect(DirectionResolver.edgeSteerAngle(0.99), isNull);
      expect(DirectionResolver.edgeSteerAngle(-e), s);
      expect(DirectionResolver.edgeSteerAngle(-2), s);
      expect(DirectionResolver.edgeSteerAngle(e), -s);
      expect(DirectionResolver.edgeSteerAngle(2), -s);
    });

    test('왼쪽 끝이면 직진·이탈·각도 없음과 무관하게 left(오른쪽으로 가라)', () {
      for (final label in ['front', 'left', 'right']) {
        for (final a in <double?>[null, 0, 40, -40]) {
          expect(DirectionResolver.resolve(label, a, position: -1.5), 'left',
              reason: '$label/$a');
        }
      }
    });

    test('오른쪽 끝이면 각도와 무관하게 right(왼쪽으로 가라)', () {
      for (final label in ['front', 'left', 'right']) {
        for (final a in <double?>[null, 0, 40, -40]) {
          expect(DirectionResolver.resolve(label, a, position: 1.5), 'right',
              reason: '$label/$a');
        }
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
}
