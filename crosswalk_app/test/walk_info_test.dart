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
    expect(ko.crosswalkAhead(46), '50미터 앞 횡단보도');
  });

  test('경로: 횡단보도(211~217)만 뽑고, 50m 안에서 한 번씩, 목적지 20m', () {
    final geo = {
      'features': [
        {'geometry': {'type': 'Point', 'coordinates': [127.0, 37.0]},
         'properties': {'turnType': 200}},
        {'geometry': {'type': 'Point', 'coordinates': [127.0, 37.001]},
         'properties': {'turnType': 212}},
        {'geometry': {'type': 'LineString', 'coordinates': []},
         'properties': {'facilityType': '15'}},
        {'geometry': {'type': 'Point', 'coordinates': [127.0, 37.003]},
         'properties': {'turnType': 201}},
      ]
    };
    final cw = parseRouteCrosswalks(geo);
    expect(cw.map((p) => p.turnType), [212]);
    final g = RouteGuide(cw, 37.003, 127.0, 'dest');
    expect(g.update(37.0, 127.0, ko), isNull); // 111m
    expect(g.update(37.0006, 127.0, ko), '40미터 앞 횡단보도');
    expect(g.update(37.0008, 127.0, ko), isNull); // 이미 말함
    expect(g.update(37.0029, 127.0, ko), '목적지 근처입니다');
    expect(g.update(37.0029, 127.0, ko), isNull);
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
}
