import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/localization/app_strings.dart';
import 'package:crosswalk_app/services/event_log.dart';
import 'package:crosswalk_app/services/feedback_service.dart';
import 'package:crosswalk_app/services/walk_info.dart';

// T198: 보행 정보 판정표·경로 안내의 순수 로직.
void main() {
  const ko = WalkStrings(AppLanguage.ko);

  test('distanceM: 위도 0.001도 ≈ 111m', () {
    expect(distanceM(37.0, 127.0, 37.001, 127.0), closeTo(111.2, 0.5));
  });

  test('nearestWithin: 반경 안 가장 가까운 것, 밖이면 null', () {
    const a = CrosswalkInfo(37.0, 127.0, src: 'a');
    const b = CrosswalkInfo(37.0001, 127.0, src: 'b'); // 약 11m
    expect(nearestWithin([a, b], 37.0002, 127.0, 30)!.src, 'b');
    expect(nearestWithin([a, b], 37.01, 127.0, 30), isNull);
  });

  test('행 파싱: 표준데이터·Signlamp, 빈 값은 정보 없음', () {
    final s = parseStdRow({
      'latitude': '37.1',
      'longitude': '127.1',
      'tfclghtYn': 'Y',
      'sondSgngnrYn': ' ',
    })!;
    expect([s.signal, s.sound, s.src], [true, null, 'std']);
    expect(parseStdRow({'latitude': '', 'longitude': '1'}), isNull);
    final g = parseSignlampRow({
      'REFINE_WGS84_LAT': 37.1,
      'REFINE_WGS84_LOGT': 127.1,
      'BLINDPSN_SOUND_MACHIN_YN': 'N',
    })!;
    expect([g.signal, g.sound], [true, false]);
  });

  test('안내 문장 판정표', () {
    expect(ko.info(const CrosswalkInfo(0, 0, signal: true, sound: true, src: 's')),
        '신호등 있음, 음향신호기 있음');
    expect(ko.info(const CrosswalkInfo(0, 0, signal: true, src: 's')),
        '신호등 있음, 음향신호기 정보 없음');
    expect(ko.info(const CrosswalkInfo(0, 0, signal: false, sound: true, src: 's')),
        '신호등 없음');
  });

  testWidgets('앞에 횡단보도 뒤에 주변 정보를 잇는다(정보 없으면 침묵)',
      (tester) async {
    EventLog.instance.clearForTest();
    final s = FeedbackService()..approachInfo = () => '신호등 있음, 음향신호기 없음';
    await s.alert('none', 0.9);
    await s.alert('approach', 0.9);
    final texts = EventLog.instance.earlyLines
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .map((m) => m['text'])
        .toList();
    expect(texts, contains('신호등 있음, 음향신호기 없음'));

    EventLog.instance.clearForTest();
    s.approachInfo = () => null;
    await s.alert('none', 0.9);
    await tester.pump(const Duration(seconds: 4));
    await s.alert('approach', 0.9);
    final again = EventLog.instance.earlyLines
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .map((m) => m['text'])
        .toList();
    expect(again, isNot(contains('신호등 있음, 음향신호기 없음')));
    unawaited(s.dispose());
    await tester.pump(const Duration(seconds: 1));
  });

  group('T205 목적지 검색', () {
    const near = Place('가까운 곳', 37, 127, 350);
    const far = Place('먼 곳', 35, 129, 250000);
    const mid = Place('중간', 37.1, 127, 12340);

    test('20km 넘는 결과는 뒤로, 나머지는 티맵 순서 그대로', () {
      expect(orderPlaces([far, mid, near]).map((p) => p.name),
          ['중간', '가까운 곳', '먼 곳']);
    });

    test('거리 말: 1km 미만 10m 단위(최소 10), 이상 0.1km 단위', () {
      expect(placeDistance(346, AppLanguage.ko), '350미터');
      expect(placeDistance(3, AppLanguage.ko), '10미터');
      expect(placeDistance(12340, AppLanguage.ko), '12.3킬로미터');
      expect(placeDistance(1000, AppLanguage.en), '1.0 kilometers');
    });

    test('목록 읽기 문장', () {
      expect(placesSpeech([near, mid], AppLanguage.ko),
          '검색 결과 2곳. 1번, 가까운 곳, 350미터. 2번, 중간, 12.3킬로미터. 안내할 곳을 고르세요');
    });

    test('SingleFlight: 진행 중 두 번째 요청은 버린다(한 번만 시작)', () async {
      final f = SingleFlight();
      var calls = 0;
      final done = Completer<void>();
      final a = f.run(() async {
        calls++;
        await done.future;
        return 1;
      });
      final b = f.run(() async {
        calls++;
        return 2;
      });
      expect(f.busy, isTrue);
      expect(await b, isNull);
      done.complete();
      expect(await a, 1);
      expect(calls, 1);
      expect(f.busy, isFalse);
      expect(await f.run(() async => 3), 3);
    });
  });
}
