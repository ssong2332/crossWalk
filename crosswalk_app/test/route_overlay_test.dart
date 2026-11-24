import 'dart:math' as math;

import 'package:crosswalk_app/localization/app_strings.dart';
import 'package:crosswalk_app/services/route_nav.dart';
import 'package:crosswalk_app/services/walk_info.dart';
import 'package:crosswalk_app/widgets/route_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// T204: 카메라 화면 미니맵만 되살림(바닥 화살표 없음).
void main() {
  // 북쪽 100m 뒤 왼쪽(12) 50m.
  const lat0 = 37.0, lon0 = 127.0;
  final dLat = 100 / 110540;
  final dLon = 50 / (111320 * math.cos(lat0 * math.pi / 180));
  final geo = RouteGeometry.fromTmap({
    'features': [
      {
        'type': 'Feature',
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            [lon0, lat0],
            [lon0, lat0 + dLat],
            [lon0 - dLon, lat0 + dLat],
          ]
        },
        'properties': {},
      },
      {
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [lon0, lat0 + dLat]},
        'properties': {'turnType': 12},
      },
    ]
  });
  final svc = WalkInfoService.instance;
  tearDown(() => svc.view.value = null);

  Future<void> pump(WidgetTester t) => t.pumpWidget(const MaterialApp(
      home: Scaffold(body: Stack(children: [Positioned.fill(child: RouteOverlay())]))));

  testWidgets('경로가 없으면 아무것도 그리지 않는다', (t) async {
    await pump(t);
    expect(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is MiniRoutePainter),
        findsNothing);
  });

  testWidgets('경로가 있으면 미니맵과 밑 글자만 그린다', (t) async {
    await pump(t);
    svc.view.value =
        RouteView(geo, const math.Point(0, 70), 70, null, '30m 왼쪽');
    await t.pump();
    final paints = find.byWidgetPredicate((w) => w is CustomPaint && w.painter != null);
    expect(paints, findsOneWidget);
    expect(t.widget<CustomPaint>(paints).painter, isA<MiniRoutePainter>());
    expect(find.text('30m 왼쪽'), findsOneWidget);
    // 왼쪽 위.
    expect(t.getTopLeft(paints).dx, lessThan(40));
  });

  group('T206 목적지 확인 글자', () {
    test('문장: 남은 경로 거리', () {
      expect(destRemainText('시청역', 346, AppLanguage.ko), '시청역까지 350미터');
      expect(destRemainText('City Hall', 1234, AppLanguage.en),
          '1.2 kilometers to City Hall');
      expect(destRemainText('시청역', -3, AppLanguage.ko), '시청역까지 10미터');
    });

    Future<List<String>> pumpLabel(WidgetTester t) async {
      final spoken = <String>[];
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Stack(children: [
        Positioned.fill(
            child: RouteOverlay(destLabel: true, onSpeak: spoken.add)),
      ]))));
      // 경로 150m 중 70m 진행 -> 80m 남음.
      svc.view.value = RouteView(
          geo, const math.Point(0, 70), 70, null, '30m 왼쪽', '시청역');
      await t.pump();
      return spoken;
    }

    testWidgets('맨 위 층: 미니맵은 투명, 글자를 누르면 같은 문장을 읽는다', (t) async {
      final spoken = await pumpLabel(t);
      expect(find.text('시청역까지 80미터'), findsOneWidget);
      final op = t.widget<Opacity>(find.ancestor(
          of: find.byWidgetPredicate(
              (w) => w is CustomPaint && w.painter is MiniRoutePainter),
          matching: find.byType(Opacity)));
      expect(op.opacity, 0);
      await t.tap(find.text('시청역까지 80미터'));
      expect(spoken, ['시청역까지 80미터']);
    });

    testWidgets('화면 읽기: 버튼 하나로 "시청역까지 80미터", 두 번 탭하면 읽기', (t) async {
      final h = t.ensureSemantics();
      final spoken = await pumpLabel(t);
      final node = t.getSemantics(find.bySemanticsLabel('시청역까지 80미터'));
      expect(
          node,
          matchesSemantics(
              label: '시청역까지 80미터', isButton: true, hasTapAction: true));
      expect(find.bySemanticsLabel('30m 왼쪽'), findsNothing);
      t.semantics.tap(find.semantics.byLabel('시청역까지 80미터'));
      expect(spoken, ['시청역까지 80미터']);
      h.dispose();
    });

    testWidgets('아래 층(기본)에는 목적지 글자가 없다', (t) async {
      await pump(t);
      svc.view.value = RouteView(
          geo, const math.Point(0, 70), 70, null, null, '시청역');
      await t.pump();
      expect(find.textContaining('까지'), findsNothing);
    });
  });
}
