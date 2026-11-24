import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:meta/meta.dart';

import '../localization/app_strings.dart';
import 'event_log.dart';
import 'feedback_service.dart';

/// T198(사용자 결정 2026-11-24): 보행 정보 — 주변 횡단보도의 신호등·음향신호기
/// 정보와 티맵 보행자 경로의 "앞 횡단보도" 안내.
///
/// 키는 CI 비밀값을 `--dart-define`으로 넣는다(build_apk.yml). APK에서 꺼낼 수
/// 있다는 위험은 사용자가 감수했다(공개 저장소, Free 요금제라 과금 없음).
/// shortcut: 키가 앱 안에 있다, 출시 전에 서버 경유로 바꾼다.
const String kTmapKey = String.fromEnvironment('TMAP_KEY');
const String kDataGoKrKey = String.fromEnvironment('DATA_GO_KR_KEY');
const String kGgKey = String.fromEnvironment('GG_KEY');

/// 주변 횡단보도 정보 판정 반경(m) — 판정표 1·2행.
const double kCrosswalkInfoRadiusM = 30;

/// 경로의 다음 횡단보도를 미리 알리는 거리(m).
const double kRouteCrosswalkNoticeM = 50;

/// 목적지 근처 안내 거리(m).
const double kRouteArriveM = 20;

/// 위치가 이보다 오래되면 주변 정보를 말하지 않는다(엉뚱한 곳 정보 방지).
const Duration kPositionMaxAge = Duration(seconds: 20);

/// 지도·공공데이터의 횡단보도 한 곳. null = 정보 없음.
@immutable
class CrosswalkInfo {
  final double lat;
  final double lon;
  final bool? signal;
  final bool? sound;
  final String src;
  const CrosswalkInfo(this.lat, this.lon,
      {this.signal, this.sound, required this.src});
}

bool? ynOrNull(Object? v) {
  final s = v?.toString().trim().toUpperCase();
  if (s == 'Y') return true;
  if (s == 'N') return false;
  return null;
}

/// 두 좌표 사이 거리(m, 하버사인).
double distanceM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * r * math.asin(math.sqrt(a));
}

/// [maxM] 안에서 가장 가까운 지점. 없으면 null.
CrosswalkInfo? nearestWithin(
    Iterable<CrosswalkInfo> items, double lat, double lon, double maxM) {
  CrosswalkInfo? best;
  var bestD = maxM;
  for (final c in items) {
    final d = distanceM(lat, lon, c.lat, c.lon);
    if (d <= bestD) {
      best = c;
      bestD = d;
    }
  }
  return best;
}

double? _num(Object? v) => v == null ? null : double.tryParse(v.toString());

/// 전국횡단보도표준데이터 한 행.
CrosswalkInfo? parseStdRow(Map<String, dynamic> r) {
  final lat = _num(r['latitude']);
  final lon = _num(r['longitude']);
  if (lat == null || lon == null) return null;
  return CrosswalkInfo(lat, lon,
      signal: ynOrNull(r['tfclghtYn']),
      sound: ynOrNull(r['sondSgngnrYn']),
      src: 'std');
}

/// 경기데이터드림 Signlamp 한 행 — 신호등 자리이므로 signal은 true.
CrosswalkInfo? parseSignlampRow(Map<String, dynamic> r) {
  final lat = _num(r['REFINE_WGS84_LAT']);
  final lon = _num(r['REFINE_WGS84_LOGT']);
  if (lat == null || lon == null) return null;
  return CrosswalkInfo(lat, lon,
      signal: true,
      sound: ynOrNull(r['BLINDPSN_SOUND_MACHIN_YN']),
      src: 'signlamp');
}

/// 보행 정보 문장(한국어·영어). app_strings의 고정 문장과 달리 숫자가 들어가서
/// 여기 함수로 둔다.
class WalkStrings {
  final AppLanguage lang;
  const WalkStrings(this.lang);
  bool get _ko => lang == AppLanguage.ko;

  /// 판정표: 신호등 없음이면 음향신호기는 말하지 않는다. 음향신호기 값이
  /// 비었으면 "정보 없음"(조사: 신호등 있는 곳의 58%가 비어 있음).
  String info(CrosswalkInfo c) {
    final parts = <String>[];
    if (c.signal == true) parts.add(_ko ? '신호등 있음' : 'signal');
    if (c.signal == false) parts.add(_ko ? '신호등 없음' : 'no signal');
    if (c.signal != false) {
      parts.add(c.sound == true
          ? (_ko ? '음향신호기 있음' : 'audible signal')
          : c.sound == false
              ? (_ko ? '음향신호기 없음' : 'no audible signal')
              : (_ko ? '음향신호기 정보 없음' : 'audible signal unknown'));
    }
    return parts.join(', ');
  }

  String crosswalkAhead(double m) {
    final r = (m / 10).round() * 10;
    return _ko ? '$r미터 앞 횡단보도' : 'Crosswalk in $r meters';
  }

  String get arrived => _ko ? '목적지 근처입니다' : 'Near your destination';
}

/// 경로 위의 안내 지점.
@immutable
class RoutePoint {
  final double lat;
  final double lon;
  final int turnType;
  const RoutePoint(this.lat, this.lon, this.turnType);
}

/// 티맵 보행자 경로(GeoJSON)에서 횡단보도(211~217) 지점만 순서대로 뽑는다.
List<RoutePoint> parseRouteCrosswalks(Map<String, dynamic> geo) {
  final out = <RoutePoint>[];
  for (final f in (geo['features'] as List? ?? const [])) {
    final g = f['geometry'];
    if (g?['type'] != 'Point') continue;
    final t = f['properties']?['turnType'];
    if (t is! int || t < 211 || t > 217) continue;
    final c = g['coordinates'] as List;
    out.add(RoutePoint(
        (c[1] as num).toDouble(), (c[0] as num).toDouble(), t));
  }
  return out;
}

/// 걸으며 받은 위치로 "N미터 앞 횡단보도"·"목적지 근처"를 한 번씩 낸다.
class RouteGuide {
  final List<RoutePoint> crosswalks;
  final double destLat;
  final double destLon;
  final String destName;
  final _announced = <int>{};
  bool _arrived = false;
  RouteGuide(this.crosswalks, this.destLat, this.destLon, this.destName);

  bool get arrived => _arrived;

  /// 이번 위치에서 말할 문장. 없으면 null.
  String? update(double lat, double lon, WalkStrings s) {
    if (_arrived) return null;
    if (distanceM(lat, lon, destLat, destLon) <= kRouteArriveM) {
      _arrived = true;
      return s.arrived;
    }
    for (var i = 0; i < crosswalks.length; i++) {
      if (_announced.contains(i)) continue;
      final d = distanceM(lat, lon, crosswalks[i].lat, crosswalks[i].lon);
      if (d <= kRouteCrosswalkNoticeM) {
        _announced.add(i);
        return s.crosswalkAhead(d);
      }
    }
    return null;
  }
}

/// 위치를 받아 주변 횡단보도 정보를 모으고, 경로 안내를 돌린다.
class WalkInfoService {
  WalkInfoService._();
  static final WalkInfoService instance = WalkInfoService._();

  StreamSubscription<Position>? _sub;
  FeedbackService? _feedback;
  Position? _last;
  String? _area;
  DateTime? _areaCheckedAt;
  List<CrosswalkInfo> _std = const [];
  List<CrosswalkInfo> _signlamp = const [];
  RouteGuide? _route;

  bool get running => _sub != null;
  RouteGuide? get route => _route;

  static bool get keysReady =>
      kTmapKey.isNotEmpty && kDataGoKrKey.isNotEmpty;

  /// 켠다. 실패하면 이유(화면 표시용), 성공하면 null.
  Future<String?> start(FeedbackService feedback) async {
    if (running) return null;
    if (!keysReady) return 'no_key';
    if (!await Geolocator.isLocationServiceEnabled()) return 'location_off';
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) {
      p = await Geolocator.requestPermission();
    }
    if (p == LocationPermission.denied ||
        p == LocationPermission.deniedForever) {
      return 'permission';
    }
    _feedback = feedback;
    feedback.approachInfo = () => approachInfo(feedback.language);
    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best, distanceFilter: 3),
    ).listen(_onPosition, onError: (Object e) {
      EventLog.instance.log('walk.error', {'where': 'gps', 'e': '$e'});
    });
    EventLog.instance.log('walk.start', const {});
    return null;
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _feedback?.approachInfo = null;
    _feedback = null;
    _route = null;
    EventLog.instance.log('walk.stop', const {});
  }

  void _onPosition(Position pos) {
    _last = pos;
    final now = DateTime.now();
    final checked = _areaCheckedAt;
    if (checked == null || now.difference(checked).inSeconds >= 60) {
      _areaCheckedAt = now;
      unawaited(_refreshArea(pos.latitude, pos.longitude));
    }
    final route = _route;
    final fb = _feedback;
    if (route != null && fb != null) {
      final msg = route.update(
          pos.latitude, pos.longitude, WalkStrings(fb.language));
      if (msg != null) {
        // 기록에는 위치를 남기지 않는다(docs/EventLog.md).
        EventLog.instance.log('walk.route', {'text': msg});
        unawaited(fb.announceRoute(msg));
      }
    }
  }

  /// 판정표 1·2행: 표준데이터 30m 안 -> 없으면 Signlamp 30m 안 -> 없으면 침묵.
  String? approachInfo(AppLanguage lang) {
    final pos = _last;
    if (pos == null ||
        DateTime.now().difference(pos.timestamp) > kPositionMaxAge) {
      return null;
    }
    final hit = nearestWithin(
            _std, pos.latitude, pos.longitude, kCrosswalkInfoRadiusM) ??
        nearestWithin(
            _signlamp, pos.latitude, pos.longitude, kCrosswalkInfoRadiusM);
    if (hit == null) return null;
    final msg = WalkStrings(lang).info(hit);
    EventLog.instance.log('walk.info', {'src': hit.src, 'text': msg});
    return msg;
  }

  Future<void> _refreshArea(double lat, double lon) async {
    try {
      final geo = await _getJson(
          Uri.https('apis.openapi.sk.com', '/tmap/geo/reversegeocoding', {
            'version': '1',
            'lat': '$lat',
            'lon': '$lon',
            'coordType': 'WGS84GEO',
            'addressType': 'A10',
          }),
          headers: {'appKey': kTmapKey});
      final a = geo['addressInfo'] as Map<String, dynamic>? ?? const {};
      final city = (a['city_do'] ?? '').toString();
      final gu = (a['gu_gun'] ?? '').toString();
      final area = '$city|$gu';
      if (area == _area || gu.isEmpty) return;
      _area = area;
      EventLog.instance.log('walk.area', {'area': area});
      _std = await _fetchStd(city, gu);
      _signlamp =
          city == '경기도' && kGgKey.isNotEmpty ? await _fetchSignlamp(gu) : const [];
      EventLog.instance.log('walk.data',
          {'area': area, 'std': _std.length, 'signlamp': _signlamp.length});
    } catch (e) {
      _area = null;
      EventLog.instance.log('walk.error', {'where': 'area', 'e': '$e'});
    }
  }

  Future<List<CrosswalkInfo>> _fetchStd(String city, String gu) async {
    final out = <CrosswalkInfo>[];
    // shortcut: 시군구당 10,000건까지만 받는다, 넘는 곳이 생기면 쪽수를 늘린다.
    for (var page = 1; page <= 10; page++) {
      final d = await _getJson(Uri.https(
          'api.data.go.kr', '/openapi/tn_pubr_public_crosswalk_api', {
        'serviceKey': kDataGoKrKey,
        'pageNo': '$page',
        'numOfRows': '1000',
        'type': 'json',
        'ctprvnNm': city,
        'signguNm': gu,
      }));
      final body = (d['response']?['body'] ?? d['body']) as Map? ?? const {};
      final items = (body['items'] is Map ? body['items']['item'] : null)
              as List? ??
          const [];
      for (final r in items) {
        final c = parseStdRow(Map<String, dynamic>.from(r as Map));
        if (c != null) out.add(c);
      }
      final total = int.tryParse('${body['totalCount']}') ?? 0;
      if (items.isEmpty || out.length >= total) break;
    }
    return out;
  }

  Future<List<CrosswalkInfo>> _fetchSignlamp(String gu) async {
    // "성남시 분당구" -> "성남시" (Signlamp는 시군 단위).
    final sigun = gu.split(' ').first;
    final out = <CrosswalkInfo>[];
    for (var page = 1; page <= 10; page++) {
      final d = await _getJson(Uri.https('openapi.gg.go.kr', '/Signlamp', {
        'KEY': kGgKey,
        'Type': 'json',
        'pIndex': '$page',
        'pSize': '1000',
        'SIGUN_NM': sigun,
      }));
      final parts = d['Signlamp'] as List?;
      if (parts == null || parts.length < 2) break; // INFO-200 = 데이터 없음
      final rows = parts[1]['row'] as List? ?? const [];
      for (final r in rows) {
        final c = parseSignlampRow(Map<String, dynamic>.from(r as Map));
        if (c != null) out.add(c);
      }
      if (rows.length < 1000) break;
    }
    return out;
  }

  /// 목적지 검색 -> 경로 받기. 성공하면 null, 실패하면 이유.
  Future<String?> startRoute(String keyword) async {
    final pos = _last;
    if (!running) return 'not_running';
    if (pos == null) return 'no_position';
    try {
      final poi = await _getJson(
          Uri.https('apis.openapi.sk.com', '/tmap/pois', {
            'version': '1',
            'searchKeyword': keyword,
            'count': '1',
            'resCoordType': 'WGS84GEO',
            'reqCoordType': 'WGS84GEO',
          }),
          headers: {'appKey': kTmapKey});
      final pois = poi['searchPoiInfo']?['pois']?['poi'] as List?;
      if (pois == null || pois.isEmpty) return 'no_place';
      final p = pois.first as Map;
      final destLat = double.parse('${p['frontLat']}');
      final destLon = double.parse('${p['frontLon']}');
      final name = '${p['name']}';
      final geo = await _postForm(
          Uri.https('apis.openapi.sk.com', '/tmap/routes/pedestrian',
              {'version': '1'}),
          {
            'startX': '${pos.longitude}',
            'startY': '${pos.latitude}',
            'endX': '$destLon',
            'endY': '$destLat',
            'startName': 'start',
            'endName': name,
            // 30 = 최단거리 + 계단 제외(시각장애 사용자).
            'searchOption': '30',
          },
          headers: {'appKey': kTmapKey});
      _route = RouteGuide(parseRouteCrosswalks(geo), destLat, destLon, name);
      EventLog.instance.log('walk.route_start',
          {'dest': name, 'crosswalks': _route!.crosswalks.length});
      return null;
    } catch (e) {
      EventLog.instance.log('walk.error', {'where': 'route', 'e': '$e'});
      return 'network';
    }
  }

  void stopRoute() => _route = null;

  static Future<Map<String, dynamic>> _getJson(Uri uri,
      {Map<String, String> headers = const {}}) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await c.getUrl(uri);
      headers.forEach(req.headers.set);
      req.headers.set('Accept', 'application/json');
      return _readJson(await req.close());
    } finally {
      c.close();
    }
  }

  static Future<Map<String, dynamic>> _postForm(
      Uri uri, Map<String, String> form,
      {Map<String, String> headers = const {}}) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await c.postUrl(uri);
      headers.forEach(req.headers.set);
      req.headers.set('Accept', 'application/json');
      req.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      req.write(Uri(queryParameters: form).query);
      return _readJson(await req.close());
    } finally {
      c.close();
    }
  }

  static Future<Map<String, dynamic>> _readJson(HttpClientResponse res) async {
    final body = await res
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      // 키가 들어간 주소는 남기지 않는다 — 상태 코드만.
      throw HttpException('HTTP ${res.statusCode}');
    }
    return jsonDecode(body) as Map<String, dynamic>;
  }
}
