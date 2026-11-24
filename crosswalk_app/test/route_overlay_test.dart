import 'dart:math' as math;

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
}
