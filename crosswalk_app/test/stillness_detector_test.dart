import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/services/stillness_detector.dart';

void main() {
  final t0 = DateTime(2026, 10, 25, 18, 9, 35);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));
  const g = 9.81;

  /// [fromMs]부터 [toMs]까지 66ms(약 15Hz)마다 표본을 넣는다. [amp]는 |a|의
  /// 사인 흔들림 진폭(m/s²) — 표준편차는 amp/√2. 상태가 바뀐 시각들을 돌려준다.
  List<int> feed(StillnessDetector d, int fromMs, int toMs,
      {double amp = 0, double hz = 2}) {
    final changes = <int>[];
    for (var ms = fromMs; ms <= toMs; ms += 66) {
      final m = g + amp * math.sin(2 * math.pi * hz * ms / 1000);
      if (d.add(0, 0, m, at(ms))) changes.add(ms);
    }
    return changes;
  }

  group('StillnessDetector (T133)', () {
    test('가만히 2초 이어지면 서 있음', () {
      final d = StillnessDetector();
      final ch = feed(d, 0, 4000, amp: 0.1);
      expect(d.isStill, isTrue);
      expect(ch.length, 1);
      // 창이 차는 데(표본 5개) 약 0.26초 + 유지 2초.
      expect(ch.single, inInclusiveRange(2000, 2500));
    });

    test('걸음(흔들림 큼)이면 서 있음이 아니다', () {
      final d = StillnessDetector();
      feed(d, 0, 5000, amp: 2.0);
      expect(d.isStill, isFalse);
      expect(d.motion, greaterThan(StillnessDetector.moveThreshold));
    });

    test('서 있다가 걸음을 떼면 바로 풀린다', () {
      final d = StillnessDetector();
      feed(d, 0, 3000, amp: 0.1);
      expect(d.isStill, isTrue);
      final ch = feed(d, 3066, 4000, amp: 2.0);
      expect(d.isStill, isFalse);
      expect(ch.single, lessThan(3500), reason: '흔들림이 창에 들어오면 바로');
    });

    test('2초가 안 되는 멈칫은 서 있음이 아니다', () {
      final d = StillnessDetector();
      feed(d, 0, 2000, amp: 2.0);
      feed(d, 2066, 3200, amp: 0.1); // 약 1.1초 조용
      feed(d, 3266, 5000, amp: 2.0);
      expect(d.isStill, isFalse);
    });

    test('그 사이 값은 지금 상태를 유지한다(이력)', () {
      final d = StillnessDetector();
      feed(d, 0, 3000, amp: 0.1);
      expect(d.isStill, isTrue);
      // 표준편차 ≈ 0.64/√2 = 0.45 — 두 기준 사이.
      feed(d, 3066, 6000, amp: 0.64);
      expect(d.isStill, isTrue);
      final e = StillnessDetector();
      feed(e, 0, 6000, amp: 0.64);
      expect(e.isStill, isFalse, reason: '서 있음 아님에서 시작하면 그대로');
    });

    test('센서가 멈추면(1초 넘게 표본 없음) 서 있다고 보지 않는다', () {
      final d = StillnessDetector();
      feed(d, 0, 3000, amp: 0.1);
      expect(d.isStillAt(at(3500)), isTrue);
      expect(d.isStillAt(at(4100)), isFalse);
    });

    test('기준값(추정): 0.35 / 0.6 m/s², 유지 2초', () {
      expect(StillnessDetector.stillThreshold, 0.35);
      expect(StillnessDetector.moveThreshold, 0.6);
      expect(StillnessDetector.holdOn, const Duration(seconds: 2));
    });
  });

  // T207 ②(사용자 결정 2026-11-25): 11/25 연석 대기 중 몸을 조금 움직이면(mot 0.6~0.9)
  // 서 있음이 풀린 채 남았다 — 음성 억제용 멈춤(isSettledAt)은 풀린 뒤 10초 안에 1초 조용하면 다시.
  group('StillnessDetector 음성 억제용 멈춤 (T207 ②)', () {
    test('풀린 직후 중간 흔들림(0.35~0.6)이 1초 이어지면 다시 멈춤, isStill은 그대로', () {
      final d = StillnessDetector();
      feed(d, 0, 3000, amp: 0.1);
      expect(d.isSettledAt(at(3000)), isTrue);
      feed(d, 3066, 3600, amp: 1.2); // 몸을 잠깐 움직임
      expect(d.isSettledAt(at(3600)), isFalse);
      // std 약 0.46 — 3번 규칙(0.35 미만 2초)으로는 서 있음이 되지 않는다.
      final ch = feed(d, 3666, 6500, amp: 0.65);
      expect(d.isStill, isFalse);
      expect(ch, isEmpty, reason: 'still 기록·서 있던 구간은 종전대로');
      expect(d.isSettledAt(at(6500)), isTrue);
    });

    test('걸음을 떼면(흔들림 큼) 다시 멈춤이 되지 않는다', () {
      final d = StillnessDetector();
      feed(d, 0, 3000, amp: 0.1);
      for (var ms = 3066; ms <= 13000; ms += 66) {
        d.add(0, 0, g + 2.0 * math.sin(2 * math.pi * 2 * ms / 1000), at(ms));
        expect(d.isSettledAt(at(ms)), ms < 3400 ? anything : isFalse);
      }
    });

    test('풀린 지 10초가 지나면 종전 규칙(0.35 미만 2초)만', () {
      final d = StillnessDetector();
      feed(d, 0, 3000, amp: 0.1);
      feed(d, 3066, 14000, amp: 2.0); // 걸음 — 풀린 지 10초 넘음
      feed(d, 14066, 18000, amp: 0.65);
      expect(d.isSettledAt(at(18000)), isFalse);
    });

    test('센서가 멈추면 멈춤 아님', () {
      final d = StillnessDetector();
      feed(d, 0, 3000, amp: 0.1);
      expect(d.isSettledAt(at(3000)), isTrue);
      expect(d.isSettledAt(at(5000)), isFalse);
    });
  });
}
