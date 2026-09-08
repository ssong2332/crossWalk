import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/services/severity_latch.dart';

/// T82: 이탈 강도가 프레임마다 뒤집혀 음성·진동·화면이 함께 흔들리던 문제를
/// 막는 래치. 순수 계산이라 시간을 직접 넣어 전 구간을 고정할 수 있다.
///
/// 핵심 규칙 두 가지:
///   1. **첫 관측은 곧바로 받는다** — dwell은 뒤집힘을 막기 위한 것이지 첫
///      경고를 늦추기 위한 것이 아니다. 처음부터 크게 벗어나 있으면 첫 마디부터
///      "즉시 ..."여야 한다.
///   2. 그 뒤의 변화는 dwell 동안 유지되어야 반영한다.
void main() {
  final t0 = DateTime(2026, 1, 1, 12, 0, 0);
  const dwell = Duration(seconds: 2);

  group('SeverityLatch — 첫 관측', () {
    test('update 전에는 약함이다', () {
      expect(SeverityLatch().isSevere, isFalse);
    });

    test('첫 관측이 심함이면 곧바로 심함이다 (첫 경고를 늦추지 않는다)', () {
      final latch = SeverityLatch(dwell: dwell);
      expect(latch.update(true, t0), isTrue);
      expect(latch.isSevere, isTrue);
    });

    test('첫 관측이 약함이면 약함이다', () {
      final latch = SeverityLatch(dwell: dwell);
      expect(latch.update(false, t0), isFalse);
    });
  });

  group('SeverityLatch — 이후의 변화는 dwell을 요구한다', () {
    test('dwell을 채우지 못한 변화는 반영하지 않는다', () {
      final latch = SeverityLatch(dwell: dwell);
      latch.update(false, t0); // 첫 관측(약함)으로 시작
      expect(latch.update(true, t0.add(const Duration(seconds: 1))), isFalse);
      // 대기 시계는 변화가 처음 관측된 t0+1s부터 돈다. t0+2999ms에는 아직
      // 1999ms뿐이라 반영되지 않고, t0+3s에 정확히 2초를 채워 반영된다.
      expect(latch.update(true, t0.add(const Duration(milliseconds: 2999))),
          isFalse);
      expect(latch.update(true, t0.add(const Duration(seconds: 3))), isTrue,
          reason: '변화 시점(t0+1s)부터 2초가 지났으므로 반영된다');
    });

    test('심함에서 약함으로 내려갈 때도 같은 dwell을 요구한다', () {
      final latch = SeverityLatch(dwell: dwell);
      latch.update(true, t0);
      expect(latch.update(false, t0.add(const Duration(seconds: 1))), isTrue,
          reason: '내려가는 변화도 곧바로 반영하지 않는다');
      expect(latch.update(false, t0.add(const Duration(seconds: 3))), isFalse);
    });

    test('되돌아오면 대기 중이던 변화가 취소된다 — 튐을 흡수한다', () {
      final latch = SeverityLatch(dwell: dwell);
      latch.update(false, t0);
      latch.update(true, t0.add(const Duration(milliseconds: 500)));
      // 되돌아왔다 -> 대기 취소
      latch.update(false, t0.add(const Duration(milliseconds: 1000)));
      // 다시 올라가도 대기 시계는 여기서 새로 시작해야 한다.
      latch.update(true, t0.add(const Duration(milliseconds: 1500)));
      expect(latch.update(true, t0.add(const Duration(milliseconds: 3000))),
          isFalse,
          reason: '되돌아온 뒤 다시 올라간 시점(1500ms)부터 2초를 채워야 한다');
      expect(latch.update(true, t0.add(const Duration(milliseconds: 3500))),
          isTrue);
    });

    test('reset하면 약함으로 돌아가고 다음 첫 관측을 곧바로 받는다', () {
      final latch = SeverityLatch(dwell: dwell);
      latch.update(true, t0);
      expect(latch.isSevere, isTrue);

      latch.reset();
      expect(latch.isSevere, isFalse);
      // 새 이탈의 첫 관측이므로 dwell 없이 즉시 반영된다.
      expect(latch.update(true, t0.add(const Duration(milliseconds: 1))),
          isTrue);
    });
  });

  group('SeverityLatch — 실기기에서 관찰된 신뢰도 흐름', () {
    // 실측(같은 세션 5초 이내 연속쌍): 0.958->0.712, 0.982->0.684,
    // 0.556->0.990처럼 변화폭이 크다. 마진(히스테리시스)으로는 못 막고
    // (해제 임계값을 0.72/0.70/0.65로 낮춰도 23.9%->21.7%/19.6%/17.4%),
    // 지속 시간으로 봐야 걸러진다.
    test('0.5초 간격으로 크게 튀는 흐름에서 보고값이 한 번도 안 바뀐다', () {
      final latch = SeverityLatch(dwell: dwell);
      const threshold = 0.80;
      const stream = [0.958, 0.712, 0.974, 0.684, 0.996, 0.705, 0.935];

      var t = t0;
      bool? first;
      for (final conf in stream) {
        t = t.add(const Duration(milliseconds: 500));
        final reported = latch.update(conf >= threshold, t);
        first ??= reported;
        expect(reported, first,
            reason: 'conf=$conf 에서 보고값이 바뀌었다 (t=$t)');
      }
      expect(first, isTrue, reason: '첫 관측 0.958이 심함이므로 심함으로 유지된다');
    });

    test('진짜로 악화되어 계속 높으면 dwell 뒤에 반영된다', () {
      final latch = SeverityLatch(dwell: dwell);
      const threshold = 0.80;
      latch.update(false, t0); // 약함으로 시작

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
