import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/services/severity_latch.dart';

/// T82: 이탈 강도가 프레임마다 뒤집혀 음성·진동·화면이 함께 흔들리던 문제를
/// 막는 래치. 순수 계산이라 시간을 직접 넣어 전 구간을 고정할 수 있다.
void main() {
  final t0 = DateTime(2026, 1, 1, 12, 0, 0);

  group('SeverityLatch — 기본 동작', () {
    test('초기값은 약함(false)이다', () {
      expect(SeverityLatch().isSevere, isFalse);
    });

    test('dwell을 채우지 못한 변화는 반영하지 않는다', () {
      final latch = SeverityLatch(dwell: const Duration(seconds: 2));
      expect(latch.update(true, t0), isFalse);
      expect(latch.update(true, t0.add(const Duration(milliseconds: 1999))),
          isFalse);
    });

    test('dwell을 채우면 반영한다 (경계 포함)', () {
      final latch = SeverityLatch(dwell: const Duration(seconds: 2));
      latch.update(true, t0);
      expect(latch.update(true, t0.add(const Duration(seconds: 2))), isTrue);
      expect(latch.isSevere, isTrue);
    });

    test('되돌아오면 대기 중이던 변화가 취소된다 — 튐을 흡수한다', () {
      final latch = SeverityLatch(dwell: const Duration(seconds: 2));
      // 실기기에서 관찰된 패턴: 큰 폭으로 튀었다가 곧 되돌아온다.
      latch.update(true, t0);
      latch.update(false, t0.add(const Duration(milliseconds: 500)));
      // 다시 true가 되어도 대기 시계는 여기서 새로 시작해야 한다.
      latch.update(true, t0.add(const Duration(milliseconds: 1000)));
      expect(latch.update(true, t0.add(const Duration(milliseconds: 2500))),
          isFalse,
          reason: '되돌아온 시점부터 2초를 다시 채워야 한다');
      expect(latch.update(true, t0.add(const Duration(milliseconds: 3000))),
          isTrue);
    });

    test('심함에서 약함으로 내려갈 때도 같은 dwell을 요구한다', () {
      final latch = SeverityLatch(dwell: const Duration(seconds: 2));
      latch.update(true, t0);
      latch.update(true, t0.add(const Duration(seconds: 2)));
      expect(latch.isSevere, isTrue);

      expect(latch.update(false, t0.add(const Duration(seconds: 3))), isTrue,
          reason: '내려가는 변화도 곧바로 반영하지 않는다');
      expect(latch.update(false, t0.add(const Duration(seconds: 5))), isFalse);
    });

    test('reset하면 약함으로 돌아가고 대기도 지워진다', () {
      final latch = SeverityLatch(dwell: const Duration(seconds: 2));
      latch.update(true, t0);
      latch.update(true, t0.add(const Duration(seconds: 2)));
      expect(latch.isSevere, isTrue);

      latch.reset();
      expect(latch.isSevere, isFalse);
      // reset 직후에는 dwell을 처음부터 다시 채워야 한다.
      expect(latch.update(true, t0.add(const Duration(seconds: 3))), isFalse);
      expect(latch.update(true, t0.add(const Duration(seconds: 5))), isTrue);
    });
  });

  group('SeverityLatch — 실기기에서 관찰된 신뢰도 흐름', () {
    // 실측(같은 세션 5초 이내 연속쌍): 0.958->0.712, 0.982->0.684,
    // 0.556->0.990처럼 변화폭이 크다. 마진(히스테리시스)으로는 못 막고
    // (해제 임계값을 0.72/0.70/0.65로 낮춰도 23.9%->21.7%/19.6%/17.4%),
    // 지속 시간으로 봐야 걸러진다.
    test('0.5초 간격으로 크게 튀는 흐름에서 보고값이 한 번도 안 바뀐다', () {
      final latch = SeverityLatch(dwell: const Duration(seconds: 2));
      const threshold = 0.80;
      const stream = [0.958, 0.712, 0.974, 0.684, 0.996, 0.705, 0.935];

      var t = t0;
      for (final conf in stream) {
        t = t.add(const Duration(milliseconds: 500));
        expect(latch.update(conf >= threshold, t), isFalse,
            reason: 'conf=$conf 에서 보고값이 바뀌었다');
      }
    });

    test('진짜로 악화되어 계속 높으면 dwell 뒤에 반영된다', () {
      final latch = SeverityLatch(dwell: const Duration(seconds: 2));
      const threshold = 0.80;

      var t = t0;
      var result = false;
      for (final conf in [0.91, 0.93, 0.88, 0.95, 0.97]) {
        t = t.add(const Duration(milliseconds: 700));
        result = latch.update(conf >= threshold, t);
      }
      expect(result, isTrue, reason: '2초 넘게 유지되면 심함으로 올라가야 한다');
    });
  });
}
