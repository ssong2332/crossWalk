import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../localization/app_strings.dart';

/// T198 턴 안내(사용자 결정 2026-11-24): 티맵 보행자 경로를 따라 회전·시설을
/// 예고한다. 플러그인에 의존하지
/// 않는 순수 로직이라 단위 테스트로 판정표를 전수 확인한다.

/// 예고 거리(m). 보행 1.4m/s 기준 약 30초 전.
const double kTurnPreM = 40;

/// 지점 안내 거리(m). PRD GPS 오차 5~15m라 이보다 가까운 판정은 믿기 어렵다(추정).
const double kTurnAtM = 12;

/// 목적지 근처(m).
const double kArriveM = 20;

/// 지나간 안내점으로 볼 거리(m, 진행 거리 기준 뒤쪽).
const double kPassedM = 5;

/// 경로 이탈: 남은 경로선까지 거리(m). GPS 오차 15m × 2.
const double kOffRouteM = 30;

/// 경로 이탈 판정에 쓰는 GPS 정확도 상한(m).
const double kOffRouteMaxAccuracyM = 25;

/// 위경도 -> 기준점 둘레 평면(m, x 동쪽 · y 북쪽).
@immutable
class LocalFrame {
  final double lat0;
  final double lon0;
  const LocalFrame(this.lat0, this.lon0);

  math.Point<double> toXY(double lat, double lon) => math.Point(
      (lon - lon0) * math.cos(lat0 * math.pi / 180) * 111320,
      (lat - lat0) * 110540);
}

@immutable
class GuidePoint {
  /// 경로 시작부터의 진행 거리(m).
  final double s;
  final int turnType;
  const GuidePoint(this.s, this.turnType);
}

/// 경로선 위 위치: 진행 거리 [s], 경로선까지 옆 거리 [d].
@immutable
class RouteFix {
  final double s;
  final double d;
  const RouteFix(this.s, this.d);
}

class RouteGeometry {
  final LocalFrame frame;
  final List<math.Point<double>> pts;
  final List<double> cum;
  final List<GuidePoint> guides;
  RouteGeometry._(this.frame, this.pts, this.cum, this.guides);

  double get length => cum.isEmpty ? 0 : cum.last;

  /// 티맵 보행자 경로(GeoJSON): LineString을 순서대로 이어 경로선을, Point의
  /// turnType을 안내점으로.
  factory RouteGeometry.fromTmap(Map<String, dynamic> geo) {
    final feats = (geo['features'] as List? ?? const []).cast<Map>();
    LocalFrame? frame;
    final pts = <math.Point<double>>[];
    final raw = <(int, double, double)>[];
    for (final f in feats) {
      final g = f['geometry'] as Map?;
      final c = g?['coordinates'] as List?;
      if (g == null || c == null) continue;
      if (g['type'] == 'LineString') {
        for (final p in c.cast<List>()) {
          final lon = (p[0] as num).toDouble();
          final lat = (p[1] as num).toDouble();
          frame ??= LocalFrame(lat, lon);
          final xy = frame.toXY(lat, lon);
          if (pts.isEmpty || pts.last.distanceTo(xy) > 0.01) pts.add(xy);
        }
      } else if (g['type'] == 'Point') {
        final t = (f['properties'] as Map?)?['turnType'];
        if (t is int) {
          raw.add((t, (c[1] as num).toDouble(), (c[0] as num).toDouble()));
        }
      }
    }
    frame ??= const LocalFrame(0, 0);
    final cum = <double>[];
    for (var i = 0; i < pts.length; i++) {
      cum.add(i == 0 ? 0 : cum[i - 1] + pts[i - 1].distanceTo(pts[i]));
    }
    final geom = RouteGeometry._(frame, pts, cum, const []);
    final guides = [
      for (final r in raw) GuidePoint(geom.locate(frame.toXY(r.$2, r.$3)).s, r.$1)
    ]..sort((a, b) => a.s.compareTo(b.s));
    return RouteGeometry._(frame, pts, cum, guides);
  }

  /// [p]를 경로선에 내린 가장 가까운 점.
  RouteFix locate(math.Point<double> p) {
    if (pts.isEmpty) return const RouteFix(0, double.infinity);
    if (pts.length == 1) return RouteFix(0, pts.first.distanceTo(p));
    var best = const RouteFix(0, double.infinity);
    for (var i = 0; i < pts.length - 1; i++) {
      final a = pts[i], b = pts[i + 1];
      final abx = b.x - a.x, aby = b.y - a.y;
      final len2 = abx * abx + aby * aby;
      final t = len2 == 0
          ? 0.0
          : (((p.x - a.x) * abx + (p.y - a.y) * aby) / len2).clamp(0.0, 1.0);
      final q = math.Point(a.x + abx * t, a.y + aby * t);
      final d = q.distanceTo(p);
      if (d < best.d) best = RouteFix(cum[i] + math.sqrt(len2) * t, d);
    }
    return best;
  }
}

/// 회전 안내인 turnType(12~19, 15 없음). 지점 안내까지 두 번 말한다.
bool isTurnType(int t) => t == 12 || t == 13 || t == 14 || (t >= 16 && t <= 19);

/// 판정표: turnType -> 말할 이름. null이면 말하지 않는다(11 직진, 1~7, 233,
/// 184~189 경유지, 200 출발, 201 목적지 — 목적지는 거리로 따로).
String? turnPhrase(int t, AppLanguage lang) {
  final ko = lang == AppLanguage.ko;
  return switch (t) {
    12 => ko ? '왼쪽' : 'left',
    13 => ko ? '오른쪽' : 'right',
    14 => ko ? '뒤로 돌기' : 'turn around',
    16 => ko ? '8시 방향' : "8 o'clock",
    17 => ko ? '10시 방향' : "10 o'clock",
    18 => ko ? '2시 방향' : "2 o'clock",
    19 => ko ? '4시 방향' : "4 o'clock",
    125 => ko ? '육교' : 'overpass',
    126 => ko ? '지하보도' : 'underpass',
    127 => ko ? '계단' : 'stairs',
    128 => ko ? '경사로' : 'ramp',
    129 => ko ? '계단과 경사로' : 'stairs and ramp',
    218 => ko ? '엘리베이터' : 'elevator',
    211 => ko ? '횡단보도' : 'crosswalk',
    212 => ko ? '왼쪽 횡단보도' : 'crosswalk on the left',
    213 => ko ? '오른쪽 횡단보도' : 'crosswalk on the right',
    214 => ko ? '8시 방향 횡단보도' : "crosswalk at 8 o'clock",
    215 => ko ? '10시 방향 횡단보도' : "crosswalk at 10 o'clock",
    216 => ko ? '2시 방향 횡단보도' : "crosswalk at 2 o'clock",
    217 => ko ? '4시 방향 횡단보도' : "crosswalk at 4 o'clock",
    _ => null,
  };
}

int roundTo10(double m) => math.max(10, (m / 10).round() * 10);

String turnPreMessage(double ahead, int t, AppLanguage lang) {
  final p = turnPhrase(t, lang)!;
  final r = roundTo10(ahead);
  return lang == AppLanguage.ko ? '$r미터 앞 $p' : '$p in $r meters';
}

String turnAtMessage(int t, AppLanguage lang) {
  final ko = lang == AppLanguage.ko;
  if (t == 14) return ko ? '뒤로 도세요' : 'Turn around now';
  final p = turnPhrase(t, lang)!;
  return ko ? '$p으로 도세요' : 'Turn $p now';
}

String arrivedMessage(AppLanguage lang) =>
    lang == AppLanguage.ko ? '목적지 근처입니다' : 'Near your destination';

String offRouteMessage(AppLanguage lang) => lang == AppLanguage.ko
    ? '경로를 벗어났습니다. 다시 찾습니다'
    : 'Off route. Finding a new route';

/// 진행 거리로 안내 문장을 정한다. 같은 지점의 예고·지점 안내는 한 번씩.
class NavGuide {
  final RouteGeometry geo;
  final _pre = <int>{};
  final _at = <int>{};
  bool arrived = false;
  NavGuide(this.geo);

  /// 이번 위치에서 말할 문장. 횡단 중이면 보류(표시하지 않으므로 다음 위치에서
  /// 남은 거리로 다시 정한다 — 늦은 말을 쌓지 않는다).
  String? message(double s, AppLanguage lang, {bool onCrosswalk = false}) {
    if (arrived) return null;
    if (geo.length - s <= kArriveM) {
      arrived = true;
      return arrivedMessage(lang);
    }
    if (onCrosswalk) return null;
    for (var i = 0; i < geo.guides.length; i++) {
      final g = geo.guides[i];
      if (turnPhrase(g.turnType, lang) == null) continue;
      final ahead = g.s - s;
      if (ahead < -kPassedM) continue;
      if (isTurnType(g.turnType) && ahead <= kTurnAtM) {
        if (_at.add(i)) {
          _pre.add(i);
          return turnAtMessage(g.turnType, lang);
        }
        continue;
      }
      if (ahead <= kTurnPreM && _pre.add(i)) {
        return turnPreMessage(ahead, g.turnType, lang);
      }
      if (ahead > kTurnPreM) break;
    }
    return null;
  }
}

/// 경로 이탈: 정확도 좋은 위치가 [kOffRouteM]보다 3번 연속, 10초 이상 멀면 true.
class OffRouteDetector {
  int _count = 0;
  DateTime? _since;

  bool update(double lateral, double accuracy, DateTime now) {
    if (accuracy > kOffRouteMaxAccuracyM) return false;
    if (lateral <= kOffRouteM) {
      reset();
      return false;
    }
    _count++;
    _since ??= now;
    return _count >= 3 && now.difference(_since!) >= const Duration(seconds: 10);
  }

  void reset() {
    _count = 0;
    _since = null;
  }
}

/// 재탐색 제한: 30초 간격, 경로당 20번(티맵 하루 무료 한도 보호).
class RerouteLimiter {
  DateTime? _last;
  int count = 0;

  bool tryAcquire(DateTime now) {
    if (count >= 20) return false;
    final last = _last;
    if (last != null && now.difference(last) < const Duration(seconds: 30)) {
      return false;
    }
    _last = now;
    count++;
    return true;
  }
}
