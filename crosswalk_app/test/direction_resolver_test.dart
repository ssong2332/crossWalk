import 'package:crosswalk_app/services/direction_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

// T85: 분류기 상태와 각도 모델이 반대면 각도 모델을 따른다.
// 근거(누수 없는 CV): 반대 방향 불일치 5장 중 각도 5 / 분류기 0 정답.
void main() {
  const n = DirectionResolver.neutralAngleDegrees;

  group('DirectionResolver.resolve', () {
    test('같은 방향이면 그대로', () {
      expect(DirectionResolver.resolve('left', 20), 'left');
      expect(DirectionResolver.resolve('right', -20), 'right');
    });

    test('반대 방향(|각도|>=5)이면 각도 방향으로 뒤집는다', () {
      // 왼쪽 이탈은 양수(오른쪽으로 가라). 음수면 실제로는 오른쪽 이탈.
      expect(DirectionResolver.resolve('left', -20), 'right');
      expect(DirectionResolver.resolve('right', 20), 'left');
      // 경계값 자체는 방향으로 친다(>=).
      expect(DirectionResolver.resolve('left', -n), 'right');
      expect(DirectionResolver.resolve('right', n), 'left');
    });

    test('중립(|각도|<5)이면 분류기 방향 유지', () {
      for (final a in <double>[0, 2, -2, 4.9, -4.9]) {
        expect(DirectionResolver.resolve('left', a), 'left', reason: '$a');
        expect(DirectionResolver.resolve('right', a), 'right', reason: '$a');
      }
    });

    test('각도가 없으면 그대로', () {
      expect(DirectionResolver.resolve('left', null), 'left');
      expect(DirectionResolver.resolve('right', null), 'right');
    });

    test('left/right 외의 상태는 각도와 무관하게 그대로', () {
      for (final label in ['front', 'approach', 'none']) {
        for (final a in <double?>[null, 30, -30, 0]) {
          expect(DirectionResolver.resolve(label, a), label,
              reason: '$label/$a');
        }
      }
    });
  });
}
