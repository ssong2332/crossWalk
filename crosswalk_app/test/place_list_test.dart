import 'package:crosswalk_app/localization/app_strings.dart';
import 'package:crosswalk_app/services/walk_info.dart';
import 'package:crosswalk_app/widgets/walk_info_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// T205: 목적지 검색 결과 목록 — 이름 + 거리, 누르면 그곳, 꺼지면 안 눌림.
void main() {
  const places = [
    Place('시청역', 37, 127, 346),
    Place('시청', 35, 129, 250000),
  ];

  Future<List<Place>> pump(WidgetTester t, {bool enabled = true}) async {
    final picked = <Place>[];
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PlaceList(
                places: places,
                language: AppLanguage.ko,
                enabled: enabled,
                onTap: picked.add))));
    return picked;
  }

  testWidgets('이름과 거리를 순서대로 보여 주고, 누른 곳을 넘긴다', (t) async {
    final picked = await pump(t);
    expect(find.text('1. 시청역'), findsOneWidget);
    expect(find.text('350미터'), findsOneWidget);
    expect(find.text('2. 시청'), findsOneWidget);
    expect(find.text('250.0킬로미터'), findsOneWidget);
    await t.tap(find.text('2. 시청'));
    expect(picked.map((p) => p.name), ['시청']);
  });

  testWidgets('진행 중(enabled=false)이면 눌러도 아무 일 없음', (t) async {
    final picked = await pump(t, enabled: false);
    await t.tap(find.text('1. 시청역'));
    expect(picked, isEmpty);
  });
}
