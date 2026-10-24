import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/services/event_log.dart';
import 'package:crosswalk_app/services/score_timeline.dart';
import 'package:crosswalk_app/widgets/haptic_score.dart';

// T129: 촉각 악보 — EventLog 사건을 시간축 자료로 모으는 규칙(ScoreTimeline 표)과
// 디버그 상자 안 표시(HapticScoreView).
void main() {
  final t0 = DateTime(2026, 10, 24, 12, 0, 0);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  group('ScoreTimeline', () {
    test('say play → 열린 발화, say.end → 같은 문장을 닫고 결과를 남긴다', () {
      final t = ScoreTimeline();
      t.add('say', {'text': '왼쪽으로 가세요', 'act': 'play', 'p': 0}, at(0));
      expect(t.speaking?.text, '왼쪽으로 가세요');
      t.add('say.end', {'text': '왼쪽으로 가세요', 'res': 'done', 'dur': 900},
          at(900));
      expect(t.speaking, isNull);
      expect(t.speech.single.end, at(900));
      expect(t.speech.single.result, 'done');
    });

    test('빠른 상승 문장은 속도를 함께 남긴다', () {
      final t = ScoreTimeline();
      t.add('say', {'text': '왼쪽! 가장자리', 'act': 'play', 'rate': 0.6}, at(0));
      expect(t.speaking?.rate, 0.6);
    });

    test('queue → 대기 목록, 같은 문장이 play로 나오면 대기에서 빠진다', () {
      final t = ScoreTimeline();
      t.add('say', {'text': '횡단보도에 진입했습니다.', 'act': 'queue'}, at(0));
      expect(t.pending.map((p) => p.text), ['횡단보도에 진입했습니다.']);
      expect(t.pending.single.deferred, isFalse);
      t.add('say', {'text': '횡단보도에 진입했습니다.', 'act': 'play'}, at(800));
      expect(t.pending, isEmpty);
      expect(t.speaking?.text, '횡단보도에 진입했습니다.');
    });

    test('say.ttl은 대기에서 빼고 만료 표시를 남긴다', () {
      final t = ScoreTimeline();
      t.add('say', {'text': '앞에 횡단보도', 'act': 'queue'}, at(0));
      t.add('say.ttl', {'text': '앞에 횡단보도', 'p': 1}, at(2500));
      expect(t.pending, isEmpty);
      expect(t.marks.single.kind, ScoreMarkKind.ttl);
      expect(t.marks.single.at, at(2500));
    });

    test('say.defer는 보류 대기, say.cancel은 취소 표시', () {
      final t = ScoreTimeline();
      t.add('say.defer', {'text': '멈춤 블록입니다'}, at(0));
      expect(t.pending.single.deferred, isTrue);
      t.add('say.cancel', {'text': '멈춤 블록입니다', 'why': 'state'}, at(500));
      expect(t.pending, isEmpty);
      expect(t.marks.single.kind, ScoreMarkKind.cancel);
    });

    test('drop은 버림 표시만 남긴다', () {
      final t = ScoreTimeline();
      t.add('say', {'text': '직진하세요', 'act': 'drop', 'why': 'slot_full'}, at(0));
      expect(t.speech, isEmpty);
      expect(t.marks.single.kind, ScoreMarkKind.drop);
    });

    test('vib 패턴의 켜짐 구간마다 진동 막대 — 왼쪽(짧게 2회)', () {
      final t = ScoreTimeline();
      t.add('vib', {
        'kind': 'left',
        'ok': true,
        'pat': [0, 125, 125, 125]
      }, at(0));
      expect(t.buzzes, hasLength(2));
      expect(t.buzzes[0].start, at(0));
      expect(t.buzzes[0].end, at(125));
      expect(t.buzzes[1].start, at(250));
      expect(t.buzzes[1].end, at(375));
    });

    test('진동기가 없으면(ok=false) 막대를 만들지 않는다', () {
      final t = ScoreTimeline();
      t.add('vib', {'kind': 'right', 'ok': false, 'why': 'no_vibrator'}, at(0));
      expect(t.buzzes, isEmpty);
    });

    test('state·pos를 받는다', () {
      final t = ScoreTimeline();
      t.add('state', {'from': 'front', 'to': 'right'}, at(0));
      t.add('pos', {'raw': 1.2, 'smooth': 1.1}, at(10));
      t.add('pos', {'raw': null, 'smooth': null}, at(20));
      expect(t.marks.single.kind, ScoreMarkKind.state);
      expect(t.marks.single.text, 'right');
      expect(t.positions.single.value, closeTo(1.1, 1e-9));
    });

    test('오래된 표시는 버리고, 끝을 못 받은 대기·발화는 30초 뒤 버린다', () {
      final t = ScoreTimeline(keep: const Duration(seconds: 5));
      t.add('say', {'text': 'a', 'act': 'play'}, at(0));
      t.add('say.end', {'text': 'a', 'res': 'done'}, at(100));
      t.add('say', {'text': 'b', 'act': 'queue'}, at(200));
      t.add('say', {'text': 'c', 'act': 'play'}, at(300));
      t.add('state', {'to': 'front'}, at(6000));
      expect(t.speech.map((s) => s.text), ['c'], reason: '닫힌 a는 창 밖');
      expect(t.pending.map((p) => p.text), ['b'], reason: '대기는 30초까지 둔다');
      t.add('state', {'to': 'none'}, at(31000));
      expect(t.pending, isEmpty);
      expect(t.speech, isEmpty);
    });

    test('모르는 사건은 무시하고 revision을 올리지 않는다', () {
      final t = ScoreTimeline();
      t.add('cls', {'best': 'front'}, at(0));
      t.add('say', {'text': 'x', 'act': 'weird'}, at(0));
      expect(t.revision, 0);
    });
  });

  group('EventLog.tap', () {
    test('기록이 꺼져 있어도 같은 사건을 받고, 구독자 예외는 삼킨다', () {
      final log = EventLog(baseDir: () async => throw UnimplementedError());
      final got = <String>[];
      log.setEnabled(false);
      log.tap = (e, d, a) {
        got.add(e);
        throw StateError('boom');
      };
      log.log('say', {'text': 'a', 'act': 'play'});
      expect(got, ['say']);
      log.tap = null;
      log.log('say', {'text': 'b', 'act': 'play'});
      expect(got, ['say']);
    });
  });

  group('HapticScoreView', () {
    Widget host(ScoreTimeline t, DateTime now, {bool reduced = true}) =>
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              child: HapticScoreView(
                timeline: t,
                reducedMotion: reduced,
                clock: () => now,
              ),
            ),
          ),
        );

    testWidgets('말하는 중·대기 줄을 글자로 보여 준다(녹화에서 읽히게)', (tester) async {
      final t = ScoreTimeline();
      t.add('say', {'text': '왼쪽으로 가세요', 'act': 'play'}, at(0));
      t.add('say', {'text': '횡단보도에 진입했습니다.', 'act': 'queue'}, at(200));
      await tester.pumpWidget(host(t, at(1500)));
      expect(find.text('말하는 중: 왼쪽으로 가세요 (1.5s)'), findsOneWidget);
      expect(find.text('대기 1.3s 횡단보도에 진입했습니다.'), findsOneWidget);
      expect(
          find.byWidgetPredicate(
              (w) => w is CustomPaint && w.painter is ScorePainter),
          findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('아무것도 없으면 빈 줄 표시', (tester) async {
      await tester.pumpWidget(host(ScoreTimeline(), at(0)));
      expect(find.text('말하는 중: —'), findsOneWidget);
      expect(find.text('대기: —'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('모션 줄이기면 매 프레임이 아니라 1초마다 다시 그린다', (tester) async {
      var builds = 0;
      final t = ScoreTimeline();
      await tester.pumpWidget(MaterialApp(
        home: HapticScoreView(
          timeline: t,
          reducedMotion: true,
          clock: () {
            builds++;
            return at(0);
          },
        ),
      ));
      final first = builds;
      await tester.pump(const Duration(milliseconds: 500));
      expect(builds, first, reason: '1초 전에는 다시 그리지 않는다');
      await tester.pump(const Duration(milliseconds: 600));
      expect(builds, first + 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('모션 줄이기가 아니면 프레임마다 다시 그린다', (tester) async {
      var builds = 0;
      await tester.pumpWidget(MaterialApp(
        home: HapticScoreView(
          timeline: ScoreTimeline(),
          reducedMotion: false,
          clock: () {
            builds++;
            return at(0);
          },
        ),
      ));
      final first = builds;
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(builds, greaterThanOrEqualTo(first + 2));
      await tester.pumpWidget(const SizedBox());
    });
  });
}
