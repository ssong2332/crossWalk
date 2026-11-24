import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../localization/app_strings.dart';

/// T198 턴 안내(사용자 결정 2026-11-24): 티맵 보행자 경로를 따라 회전·시설을
/// 예고하고, 카메라 위 바닥 화살표·미니맵에 쓸 기하를 낸다. 플러그인에 의존하지
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

/// 한국의 자기 편각(진북 기준, 서쪽 음수).
/// shortcut: 전국 고정값 -8.5도(추정), 지역별 오차가 문제되면 위도·경도로 계산한다.
const double kMagneticDeclinationDeg = -8.5;

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

  /// 진행 거리 [s]에서 경로의 방위(도, 진북 0 · 시계방향 +).
  double bearingAt(double s) {
    if (pts.length < 2) return 0;
    var i = 0;
    while (i < pts.length - 2 && cum[i + 1] <= s) {
      i++;
    }
    final a = pts[i], b = pts[i + 1];
    return _norm(math.atan2(b.x - a.x, b.y - a.y) * 180 / math.pi);
  }
}

double _norm(double deg) => (deg % 360 + 360) % 360;

/// -180~180으로.
double angleDiff(double a, double b) => (a - b + 540) % 360 - 180;

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

  /// 아직 지나지 않은 다음 회전 안내점.
  GuidePoint? nextTurn(double s) {
    for (final g in geo.guides) {
      if (isTurnType(g.turnType) && g.s - s >= -kPassedM) return g;
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

/// 나침반: 중력·자기장(기기 좌표)으로 후면 카메라가 보는 방향의 방위(진북,
/// 도). 계산 불가(자기장이 중력과 나란함 등)면 null.
double? compassHeading(List<double> g, List<double> m) {
  // Android SensorManager.getRotationMatrix와 같은 방식: E = m × g, N = g × E.
  var ex = m[1] * g[2] - m[2] * g[1];
  var ey = m[2] * g[0] - m[0] * g[2];
  var ez = m[0] * g[1] - m[1] * g[0];
  final en = math.sqrt(ex * ex + ey * ey + ez * ez);
  final gn = math.sqrt(g[0] * g[0] + g[1] * g[1] + g[2] * g[2]);
  if (en < 0.1 || gn < 0.1) return null;
  ex /= en;
  ey /= en;
  ez /= en;
  final ax = g[0] / gn, ay = g[1] / gn;
  // N = g × E. 후면 카메라 방향은 기기 -Z라 E·N의 z 성분만 쓴다.
  final nz = ax * ey - ay * ex;
  final east = -ez, north = -nz;
  return _norm(
      math.atan2(east, north) * 180 / math.pi + kMagneticDeclinationDeg);
}

/// 방위 표본들의 원형 퍼짐(도). 표본이 2개 미만이면 null.
double? headingSpread(List<double> degs) {
  if (degs.length < 2) return null;
  var c = 0.0, s = 0.0;
  for (final d in degs) {
    c += math.cos(d * math.pi / 180);
    s += math.sin(d * math.pi / 180);
  }
  final r = math.sqrt(c * c + s * s) / degs.length;
  if (r >= 1) return 0;
  return math.sqrt(-2 * math.log(r)) * 180 / math.pi;
}

/// 화살표 진하기: 1 = 또렷, 0.35 = 흐리게, 0 = 숨김.
double arrowAlpha({
  required double? heading,
  required double gpsAccuracy,
  required bool fromGps,
  double? compassSpread,
}) {
  if (heading == null || gpsAccuracy > 40) return 0;
  final spread = fromGps ? 0.0 : (compassSpread ?? 90);
  if (spread > 45) return 0;
  if (gpsAccuracy > 25 || spread > 20) return 0.35;
  return 1;
}

/// 바닥 화살표 경로(카메라 기준 지면 좌표, x 오른쪽 · z 앞, m).
/// 꺾이는 위치는 GPS 좌표가 아니라 "다음 회전까지 남은 경로 거리"로 정한다.
List<math.Point<double>> arrowPath({
  required double routeBearing,
  required double heading,
  double? turnAhead,
  double? turnBearing,
  double maxLen = 30,
  double tail = 8,
  double start = 1.8,
  double step = 0.5,
}) {
  final out = <math.Point<double>>[];
  final t1 = angleDiff(routeBearing, heading) * math.pi / 180;
  final bends = turnAhead != null && turnBearing != null && turnAhead <= maxLen;
  final len = bends ? math.max(start, turnAhead) : maxLen;
  for (var d = start; d <= len + 1e-9; d += step) {
    out.add(math.Point(d * math.sin(t1), d * math.cos(t1)));
  }
  if (bends) {
    final c = math.Point(len * math.sin(t1), len * math.cos(t1));
    final t2 = angleDiff(turnBearing, heading) * math.pi / 180;
    for (var d = step; d <= tail + 1e-9; d += step) {
      out.add(math.Point(c.x + d * math.sin(t2), c.y + d * math.cos(t2)));
    }
  }
  return out;
}
