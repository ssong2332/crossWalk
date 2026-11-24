import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/localization/app_strings.dart';
import 'package:crosswalk_app/services/route_nav.dart';

// T198 턴 안내: 판정표·이탈 판정.
void main() {
  const ko = AppLanguage.ko;
  // 가상 경로: (37,127)에서 북쪽 100m, 왼쪽(서쪽)으로 꺾어 50m.
  const lat0 = 37.0, lon0 = 127.0;
  final dLat100 = 100 / 110540;
  final dLon50 = 50 / (111320 * math.cos(lat0 * math.pi / 180));
  Map<String, dynamic> pt(double lat, double lon, int t) => {
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [lon, lat]},
        'properties': {'turnType': t},
      };
  Map<String, dynamic> line(List<List<double>> c) => {
        'type': 'Feature',
        'geometry': {'type': 'LineString', 'coordinates': c},
        'properties': {'facilityType': '11'},
      };
  final geo = {
    'features': [
      pt(lat0, lon0, 200),
      line([
        [lon0, lat0],
        [lon0, lat0 + dLat100],
      ]),
      pt(lat0 + dLat100, lon0, 12),
      line([
        [lon0, lat0 + dLat100],
        [lon0 - dLon50, lat0 + dLat100],
      ]),
      pt(lat0 + dLat100, lon0 - dLon50, 201),
    ]
  };

  group('경로 기하', () {
    test('길이·안내점 진행 거리', () {
      final g = RouteGeometry.fromTmap(geo);
      expect(g.length, closeTo(150, 0.5));
      expect(g.guides.map((e) => e.turnType), [200, 12, 201]);
      expect(g.guides[1].s, closeTo(100, 0.5));
    });

    test('옆으로 20m 떨어진 점 -> 진행 50m, 옆 거리 20m', () {
      final g = RouteGeometry.fromTmap(geo);
      final f = g.locate(const math.Point(20, 50));
      expect(f.s, closeTo(50, 0.5));
      expect(f.d, closeTo(20, 0.5));
    });
  });

  test('turnType 판정표', () {
    final expected = {
      12: '왼쪽', 13: '오른쪽', 14: '뒤로 돌기', 16: '8시 방향', 17: '10시 방향',
      18: '2시 방향', 19: '4시 방향', 125: '육교', 126: '지하보도', 127: '계단',
      128: '경사로', 129: '계단과 경사로', 218: '엘리베이터', 211: '횡단보도',
      212: '왼쪽 횡단보도', 213: '오른쪽 횡단보도', 214: '8시 방향 횡단보도',
      215: '10시 방향 횡단보도', 216: '2시 방향 횡단보도', 217: '4시 방향 횡단보도',
    };
    expected.forEach((t, p) => expect(turnPhrase(t, ko), p, reason: '$t'));
    for (final t in [1, 7, 11, 184, 189, 200, 201, 233]) {
      expect(turnPhrase(t, ko), isNull, reason: '$t');
    }
    expect([for (var t = 11; t <= 20; t++) if (isTurnType(t)) t],
        [12, 13, 14, 16, 17, 18, 19]);
    expect(turnAtMessage(12, ko), '왼쪽으로 도세요');
    expect(turnAtMessage(14, ko), '뒤로 도세요');
    expect(turnPreMessage(35, 17, ko), '40미터 앞 10시 방향');
  });

  group('NavGuide', () {
    test('예고 40m·지점 12m 한 번씩, 목적지 20m', () {
      final n = NavGuide(RouteGeometry.fromTmap(geo));
      expect(n.message(0, ko), isNull); // 100m 남음
      expect(n.message(65, ko), '40미터 앞 왼쪽');
      expect(n.message(70, ko), isNull);
      expect(n.message(90, ko), '왼쪽으로 도세요');
      expect(n.message(92, ko), isNull);
      expect(n.message(110, ko), isNull);
      expect(n.message(132, ko), '목적지 근처입니다');
      expect(n.arrived, isTrue);
      expect(n.message(140, ko), isNull);
    });

    test('횡단 중에는 보류 — 건넌 뒤 남은 거리로 다시', () {
      final n = NavGuide(RouteGeometry.fromTmap(geo));
      expect(n.message(65, ko, onCrosswalk: true), isNull);
      expect(n.message(80, ko), '20미터 앞 왼쪽');
    });

    test('바로 지점 안에서 시작하면 예고 없이 지점 안내', () {
      final n = NavGuide(RouteGeometry.fromTmap(geo));
      expect(n.message(95, ko), '왼쪽으로 도세요');
      expect(n.message(96, ko), isNull);
    });
  });

  test('경로 이탈: 30m 밖 3번 연속 + 10초, 정확도 나쁜 위치는 무시', () {
    final d = OffRouteDetector();
    final t0 = DateTime(2026, 11, 24, 12);
    expect(d.update(40, 10, t0), isFalse);
    expect(d.update(40, 50, t0.add(const Duration(seconds: 3))), isFalse);
    expect(d.update(40, 10, t0.add(const Duration(seconds: 5))), isFalse);
    expect(d.update(40, 10, t0.add(const Duration(seconds: 11))), isTrue);
    d.reset();
    expect(d.update(40, 10, t0), isFalse);
    expect(d.update(10, 10, t0.add(const Duration(seconds: 2))), isFalse);
    expect(d.update(40, 10, t0.add(const Duration(seconds: 4))), isFalse);
    expect(d.update(40, 10, t0.add(const Duration(seconds: 6))), isFalse);
  });

  test('재탐색 제한: 30초 간격, 20번', () {
    final l = RerouteLimiter();
    final t0 = DateTime(2026, 11, 24, 12);
    expect(l.tryAcquire(t0), isTrue);
    expect(l.tryAcquire(t0.add(const Duration(seconds: 10))), isFalse);
    expect(l.tryAcquire(t0.add(const Duration(seconds: 31))), isTrue);
    var t = t0.add(const Duration(seconds: 31));
    for (var i = 0; i < 30; i++) {
      t = t.add(const Duration(seconds: 31));
      l.tryAcquire(t);
    }
    expect(l.count, 20);
  });
}
