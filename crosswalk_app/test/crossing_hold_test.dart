// T103: "횡단 중" 유지(CrossingHold) 판정표 테스트.
// 순수 로직이라 플랫폼 채널이 필요 없다. 시간은 인자로 주입한다.
import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/services/crossing_hold.dart';

void main() {
  const hold = CrossingHold.holdLabel;
  final t0 = DateTime(2026, 9, 27, 12, 0, 0);
  DateTime at(int s) => t0.add(Duration(seconds: s));

  test('유지 시간은 10초다(사용자 확정)', () {
    expect(CrossingHold.holdDuration, const Duration(seconds: 10));
  });

  test('위 -> none/approach면 hold 시작', () {
    for (final on in ['front', 'left', 'right']) {
      for (final gap in ['none', 'approach']) {
        final h = CrossingHold();
        expect(h.apply(on, gap, t0), hold, reason: '$on -> $gap');
        expect(h.isHolding, isTrue);
      }
    }
  });

  test('hold는 10초 미만 동안 유지, 10초가 되면 해제되고 이번 판정 그대로', () {
    final h = CrossingHold();
    expect(h.apply('front', 'none', at(0)), hold);
    expect(h.apply(hold, 'approach', at(5)), hold);
    expect(h.apply(hold, 'none', at(9)), hold);
    expect(h.apply(hold, 'none', at(10)), 'none');
    expect(h.isHolding, isFalse);
    // 해제된 뒤에는 다시 붙잡지 않는다(직전 상태가 none).
    expect(h.apply('none', 'none', at(11)), 'none');
  });

  test('hold 중 위가 다시 보이면 해제하고 위로 돌아간다', () {
    final h = CrossingHold();
    h.apply('left', 'none', at(0));
    expect(h.apply(hold, 'front', at(3)), 'front');
    expect(h.isHolding, isFalse);
    // 다시 줄무늬가 사라지면 새로 10초를 센다.
    expect(h.apply('front', 'none', at(20)), hold);
    expect(h.apply(hold, 'none', at(29)), hold);
  });

  test('hold 중 crossed가 오면 해제하고 crossed', () {
    final h = CrossingHold();
    h.apply('front', 'none', at(0));
    expect(h.apply(hold, 'crossed', at(4)), 'crossed');
    expect(h.isHolding, isFalse);
  });

  test('위가 아닌 곳(none/approach/crossed)에서 온 none/approach는 붙잡지 않는다', () {
    for (final prev in ['none', 'approach', 'crossed', '']) {
      final h = CrossingHold();
      expect(h.apply(prev, 'none', t0), 'none', reason: prev);
      expect(h.apply(prev, 'approach', t0), 'approach', reason: prev);
    }
  });

  test('위 -> 위, 위 -> crossed는 그대로', () {
    final h = CrossingHold();
    expect(h.apply('front', 'left', t0), 'left');
    expect(h.apply('left', 'crossed', t0), 'crossed');
    expect(h.isHolding, isFalse);
  });

  // T118(A2): 발밑이 인도면 일찍 해제.
  group('발밑이 인도면 일찍 해제 (T118)', () {
    test('기준은 인도+점자블록 50%, 2회 연속', () {
      expect(CrossingHold.groundReleaseRatio, 0.5);
      expect(CrossingHold.groundReleaseFrames, 2);
    });

    test('hold 중 2회 연속 넘으면 다음 판정에서 해제하고 이번 판정 그대로', () {
      final h = CrossingHold();
      expect(h.apply('front', 'none', at(0)), hold);
      h.noteGround(0.96);
      expect(h.apply(hold, 'none', at(1)), hold, reason: '1회는 아직');
      expect(h.releasedByGround, isFalse);
      h.noteGround(1.0);
      expect(h.apply(hold, 'none', at(2)), 'none');
      expect(h.releasedByGround, isTrue);
      expect(h.isHolding, isFalse);
      // 다음 판정에서는 다시 꺼진다.
      expect(h.apply('none', 'none', at(3)), 'none');
      expect(h.releasedByGround, isFalse);
    });

    test('중간에 기준 밑이 끼면 다시 센다 (X형 가운데 아스팔트)', () {
      final h = CrossingHold();
      h.apply('front', 'none', at(0));
      h.noteGround(0.9);
      h.noteGround(0.1);
      h.noteGround(0.9);
      expect(h.apply(hold, 'approach', at(3)), hold);
      expect(h.releasedByGround, isFalse);
    });

    test('hold가 아닐 때 본 인도는 세지 않는다', () {
      final h = CrossingHold();
      h.noteGround(1.0);
      h.noteGround(1.0);
      expect(h.apply('front', 'none', at(0)), hold,
          reason: '횡단보도 위에서 줄무늬가 사라지면 평소처럼 붙잡는다');
      expect(h.releasedByGround, isFalse);
    });

    test('해제 뒤 새 hold는 처음부터 센다', () {
      final h = CrossingHold();
      h.apply('front', 'none', at(0));
      h.noteGround(1.0);
      h.noteGround(1.0);
      expect(h.apply(hold, 'none', at(1)), 'none');
      expect(h.apply('front', 'none', at(5)), hold);
      expect(h.releasedByGround, isFalse);
    });

    test('일찍 해제한 판정에서만 그 hold의 시작 시각을 알려 준다 (T118 보완)', () {
      final h = CrossingHold();
      expect(h.apply('front', 'none', at(0)), hold);
      expect(h.releasedHoldStartedAt, isNull);
      h.noteGround(1.0);
      h.noteGround(1.0);
      expect(h.apply(hold, 'none', at(4)), 'none');
      expect(h.releasedHoldStartedAt, at(0));
      expect(h.apply('none', 'none', at(5)), 'none');
      expect(h.releasedHoldStartedAt, isNull);
    });
  });
}
