// T190: 연석에서 서서 기다리다 발밑 인도 해제가 나면 "건넜습니다"를 말하지 않는다.
// 11/12 기록(`logs/crosswalk log 2bccfa2.txt`)의 위 지속·still 구간을 가속도 표본으로
// 다시 만든다. still은 서고 약 3초 뒤 켜진다(1초 창 + 2초 유지). 시각은 위로 들어온
// 순간(0초)부터 초 단위, 해제는 [dur]초.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/services/event_log.dart';
import 'package:crosswalk_app/services/feedback_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const crossedMsg = '횡단보도를 건넜습니다.';
  final base = DateTime(2026, 11, 12, 13, 50, 0);
  DateTime at(double s) => base.add(Duration(milliseconds: (s * 1000).round()));

  void stand(FeedbackService s, double from, double to) {
    for (var t = from; t <= to; t += 0.066) {
      s.addAccelerometer(0, 0, 9.81, at(t));
    }
  }

  void walk(FeedbackService s, double from, double to) {
    var i = 0;
    for (var t = from; t <= to; t += 0.066) {
      s.addAccelerometer(0, 0, (i++).isEven ? 12.0 : 7.6, at(t));
    }
  }

  List<Map<String, dynamic>> cancels() => EventLog.instance.earlyLines
      .map((l) => jsonDecode(l) as Map<String, dynamic>)
      .where((m) => m['ev'] == 'say.cancel' && m['why'] == 'no_walk_crossed')
      .toList();

  /// [plan]: ('w'|'s', 시작초, 끝초). 끝나면 [dur]초에 발밑 인도 해제(T140 위 6초 통과).
  (FeedbackService, bool) release(List<(String, double, double)> plan, double dur) {
    final s = FeedbackService();
    final first = plan.first.$2;
    walk(s, first - 3, first - 0.066);
    for (final (kind, a, b) in plan) {
      kind == 'w' ? walk(s, a, b) : stand(s, a, b);
    }
    final said = s.noteHoldReleasedByGround(at(dur),
        crossed: true,
        onDuration: Duration(milliseconds: (dur * 1000).round()));
    return (s, said);
  }

  setUp(EventLog.instance.clearForTest);

  group('기준값', () {
    test('기다림 9.5초, 기다림 뒤 6초', () {
      expect(FeedbackService.noWalkCrossedWait,
          const Duration(milliseconds: 9500));
      expect(FeedbackService.noWalkCrossedAfterWait, const Duration(seconds: 6));
    });
  });

  group('거짓 건넜습니다 — 막는다', () {
    test('11/12 13:54:09.1: 해제 순간 서 있음 (위 9.3초, 걸음 6.4초)', () {
      final (s, said) = release([('w', 0, 3.4), ('s', 3.47, 9.26)], 9.26);
      expect(s.lastReleaseWalk!.inMilliseconds, greaterThanOrEqualTo(6000),
          reason: 'T157 걸음 6초는 통과했다');
      expect(said, isFalse);
      expect(cancels().single,
          allOf(containsPair('text', crossedMsg), containsPair('rule', 'still')));
      expect(s.decidePhaseMessage('right', 'approach', at(9.26)), isNull);
    });

    test('11/12 13:58:15.8: 29.8초 기다린 뒤 5.3초 만에 해제 (위 38.9초, 걸음 9.1초)', () {
      final (s, said) =
          release([('w', 0, 0.8), ('s', 0.87, 33.6), ('w', 33.67, 38.9)], 38.9);
      expect(s.lastReleaseWalk!.inMilliseconds, greaterThanOrEqualTo(6000));
      expect(said, isFalse);
      final c = cancels().single;
      expect(c['rule'], 'wait');
      expect(c['wait_ms'] as int, greaterThan(29000));
      expect(c['after_ms'] as int, lessThan(6000));
      expect(s.decidePhaseMessage('right', 'none', at(38.9)), isNull);
    });

    test('11/12 14:03:39.3: 10.1초 기다린 뒤 2.6초 만에 해제 (위 18.7초)', () {
      final (s, said) =
          release([('w', 0, 2.9), ('s', 2.97, 16.0), ('w', 16.07, 18.65)], 18.65);
      expect(s.lastReleaseWalk!.inMilliseconds, greaterThanOrEqualTo(6000));
      expect(said, isFalse);
      expect(cancels().single['rule'], 'wait');
    });
  });

  group('실제 건넘 — 지금처럼 말한다', () {
    test('11/12 13:54:49.3: 10.1초 기다린 뒤 15.4초 걸어 건넘', () {
      final (s, said) =
          release([('w', 0, 2.3), ('s', 2.37, 15.4), ('w', 15.47, 30.8)], 30.8);
      expect(said, isTrue);
      expect(cancels(), isEmpty);
      expect(s.decidePhaseMessage('front', 'none', at(30.8)), crossedMsg);
    });

    test('11/12 14:08:44.8: 멈춤 없이 6.6초', () {
      final (_, said) = release([('w', 0, 6.6)], 6.6);
      expect(said, isTrue);
      expect(cancels(), isEmpty);
    });

    test('11/09 12:49:01.3: 10초 대기 → 9.5초 걷고 8.7초 섬 → 1.8초 (짧은 정지는 대기 아님)', () {
      final (_, said) = release([
        ('s', -2.4, 10.6),
        ('w', 10.67, 17.1),
        ('s', 17.17, 28.8),
        ('w', 28.87, 30.6),
      ], 30.6);
      expect(said, isTrue);
      expect(cancels(), isEmpty);
    });

    test('11/06 13:14:18.7: 13초 대기 뒤 6.8초(중간 1.6초 정지 포함)', () {
      final (_, said) = release([
        ('w', 0, 3.2),
        ('s', 3.27, 19.2),
        ('w', 19.27, 20.0),
        ('s', 20.07, 24.6),
        ('w', 24.67, 26.0),
      ], 26.0);
      expect(said, isTrue);
      expect(cancels(), isEmpty);
    });

    test('T140 조건이 아니면(crossed=false) 따로 기록하지 않는다', () {
      final s = FeedbackService();
      stand(s, -3, 9);
      expect(
          s.noteHoldReleasedByGround(at(9),
              crossed: false, onDuration: const Duration(seconds: 9)),
          isFalse);
      expect(cancels(), isEmpty);
    });
  });
}
