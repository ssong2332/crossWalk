// T67: 화살표 회전에 쓰는 각도 스무딩·히스테리시스 로직 단위 테스트.
// 플러그인 의존이 없는 순수 로직이라 위젯 없이 그대로 검증한다.
import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/services/stripe_direction_estimator.dart';

void main() {
  group('StripeAngleSmoother — 신뢰도 게이트', () {
    test('신뢰도가 minConfidence 미만이면 각도를 받지 않는다', () {
      final s = StripeAngleSmoother(minConfidence: 0.25);
      // 화면 표시용 임계값(0.2)은 넘지만 화살표 회전 기준(0.25)에는 못 미친다.
      expect(s.add(const StripeDirectionEstimate(20, 0.22)), isNull);
      expect(s.angleDegrees, isNull);
    });

    test('신뢰도가 충분하면 첫 값을 그대로 채택한다', () {
      final s = StripeAngleSmoother();
      expect(s.add(const StripeDirectionEstimate(20, 0.5)), 20);
    });
  });

  group('StripeAngleSmoother — 떨림 억제(EMA)', () {
    test('두 번째 값부터는 곧바로 튀지 않고 점진적으로 따라간다', () {
      final s = StripeAngleSmoother(smoothingFactor: 0.35);
      s.add(const StripeDirectionEstimate(0, 0.5));

      final after = s.add(const StripeDirectionEstimate(20, 0.5))!;
      // 0 + (20 - 0) * 0.35 = 7.0 — 20으로 즉시 점프하지 않는다.
      expect(after, closeTo(7.0, 0.001));
      expect(after, lessThan(20));
    });

    test('같은 값이 계속 들어오면 결국 그 값에 수렴한다', () {
      final s = StripeAngleSmoother(smoothingFactor: 0.35);
      s.add(const StripeDirectionEstimate(0, 0.5));
      for (var i = 0; i < 30; i++) {
        s.add(const StripeDirectionEstimate(30, 0.5));
      }
      expect(s.angleDegrees, closeTo(30, 0.1));
    });

    test('음수 각도도 동일하게 동작한다', () {
      final s = StripeAngleSmoother(smoothingFactor: 0.5);
      s.add(const StripeDirectionEstimate(0, 0.5));
      expect(s.add(const StripeDirectionEstimate(-40, 0.5)), closeTo(-20, 0.001));
    });
  });

  group('StripeAngleSmoother — 무판정 히스테리시스', () {
    test('한 번의 무판정으로는 각도를 놓지 않는다 (깜빡임 방지)', () {
      final s = StripeAngleSmoother(missTolerance: 3);
      s.add(const StripeDirectionEstimate(20, 0.5));

      expect(s.add(null), 20, reason: '1회 무판정에서는 직전 각도를 유지해야 한다');
      expect(s.add(null), 20, reason: '2회까지도 유지');
    });

    test('missTolerance만큼 연속 무판정이면 각도를 놓는다', () {
      final s = StripeAngleSmoother(missTolerance: 3);
      s.add(const StripeDirectionEstimate(20, 0.5));

      s.add(null);
      s.add(null);
      expect(s.add(null), isNull, reason: '3회 연속이면 놓아야 한다');
      expect(s.angleDegrees, isNull);
    });

    test('중간에 유효한 값이 들어오면 연속 카운트가 초기화된다', () {
      final s = StripeAngleSmoother(missTolerance: 3);
      s.add(const StripeDirectionEstimate(20, 0.5));

      s.add(null);
      s.add(null);
      s.add(const StripeDirectionEstimate(20, 0.5)); // 리셋
      s.add(null);
      s.add(null);
      expect(s.angleDegrees, isNotNull, reason: '카운트가 초기화됐어야 한다');
    });

    test('신뢰도 미달도 무판정과 같이 연속 카운트에 들어간다', () {
      final s = StripeAngleSmoother(missTolerance: 2, minConfidence: 0.25);
      s.add(const StripeDirectionEstimate(20, 0.5));

      s.add(const StripeDirectionEstimate(20, 0.1));
      expect(s.add(const StripeDirectionEstimate(20, 0.1)), isNull);
    });
  });

  group('StripeAngleSmoother — reset', () {
    test('reset은 각도와 연속 카운트를 모두 비운다', () {
      final s = StripeAngleSmoother(missTolerance: 3);
      s.add(const StripeDirectionEstimate(20, 0.5));
      s.add(null);

      s.reset();
      expect(s.angleDegrees, isNull);

      // 카운트도 비워졌으므로, 새 값이 들어오면 곧바로 그 값이 채택된다.
      expect(s.add(const StripeDirectionEstimate(-15, 0.5)), -15);
    });
  });
}
