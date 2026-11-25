import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../localization/app_strings.dart';
import '../services/route_nav.dart';
import '../services/walk_info.dart';

/// T204(사용자 결정 2026-11-24): 카메라 화면의 작은 경로선 미니맵(배경 지도 없음).
/// T198의 바닥 화살표는 T203에서 지웠고 미니맵만 되살렸다. 경로가 없으면 아무것도
/// 그리지 않는다. 미니맵·밑 글자는 음성으로 같은 안내가 나가므로 화면 읽기에서 뺀다.
///
/// T206: 미니맵 옆에 "OO까지 N미터" 글자 — 누르면 [onSpeak]로 같은 문장을 읽는다.
///
/// T209: 위쪽 큰 안내 글자와 겹치지 않도록 카메라 화면 Column 안, 아래 카드 바로
/// 위에 한 줄로 놓는다(미니맵 왼쪽, 글자 오른쪽). 미니맵 크기 104는 유지.
class RouteOverlay extends StatelessWidget {
  const RouteOverlay(
      {super.key, this.language = AppLanguage.ko, this.onSpeak});
  final AppLanguage language;
  final ValueChanged<String>? onSpeak;

  static const steel = Color(0xFFA8CDE8);

  @override
  Widget build(BuildContext context) {
    final svc = WalkInfoService.instance;
    return ValueListenableBuilder<RouteView?>(
      valueListenable: svc.view,
      builder: (context, v, _) {
        if (v == null) return const SizedBox.shrink();
        final name = v.dest;
        final text = name == null
            ? null
            : destRemainText(name, v.geo.length - v.s, language);
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: IgnorePointer(
                  child: Container(
                    width: 104,
                    height: 104,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: CustomPaint(painter: MiniRoutePainter(v)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (v.caption != null)
                      ExcludeSemantics(
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          color: Colors.black,
                          child: Text(v.caption!,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ),
                    if (text != null)
                      Semantics(
                        button: true,
                        label: text,
                        excludeSemantics: true,
                        onTap: () => onSpeak?.call(text),
                        child: GestureDetector(
                          onTap: () => onSpeak?.call(text),
                          child: Container(
                            // T209: 24sp 흰 글자, 불투명 검정 바탕, 누르는 영역 48dp 이상.
                            constraints: const BoxConstraints(
                                minWidth: 48, minHeight: 48),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                            color: Colors.black,
                            // shortcut: 아주 긴 이름은 3줄에서 자른다(누르기·화면 읽기는
                            // 전체 문장) — 메인 화면 높이를 넘지 않게.
                            child: Text(text,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 24,
                                    fontWeight: FontWeight.w700)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// T206: 안내 중 목적지 확인 문장 — "시청역까지 350미터"(남은 경로 거리).
String destRemainText(String name, double remainM, AppLanguage lang) {
  final d = placeDistance(remainM < 0 ? 0 : remainM, lang);
  return lang == AppLanguage.ko ? '$name까지 $d' : '$d to $name';
}

/// 위쪽 모서리 미니맵: 내 위치 둘레 약 60m, 진행 방향이 위(방향을 모르면 북쪽 위).
class MiniRoutePainter extends CustomPainter {
  MiniRoutePainter(this.v);
  final RouteView v;

  static const rangeM = 60.0;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height * 0.62);
    final scale = size.width / rangeM;
    // 방위 θ(시계방향)를 화면 위로 보내려면 반시계 +θ 회전.
    final rot = (v.heading ?? 0) * math.pi / 180;
    final cosR = math.cos(rot), sinR = math.sin(rot);
    Offset toScreen(math.Point<double> p) {
      final dx = p.x - v.me.x, dy = p.y - v.me.y;
      final x = dx * cosR - dy * sinR;
      final y = dx * sinR + dy * cosR;
      return c + Offset(x * scale, -y * scale);
    }

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final g = v.geo;
    final done = Paint()
      ..strokeWidth = 3
      ..color = Colors.white24;
    final todo = Paint()
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..color = RouteOverlay.steel;
    // 지나온 구간은 흐리게, 남은 구간은 스틸색.
    for (var i = 0; i < g.pts.length - 1; i++) {
      canvas.drawLine(toScreen(g.pts[i]), toScreen(g.pts[i + 1]),
          g.cum[i + 1] <= v.s ? done : todo);
    }
    for (final gp in g.guides) {
      if (gp.s < v.s - kPassedM) continue;
      final xy = _pointAtS(g, gp.s);
      final o = toScreen(xy);
      final crosswalk = gp.turnType >= 211 && gp.turnType <= 217;
      if (crosswalk) {
        canvas.drawRect(Rect.fromCenter(center: o, width: 8, height: 5),
            Paint()..color = Colors.white);
      } else if (isTurnType(gp.turnType)) {
        canvas.drawCircle(o, 3.5, Paint()..color = Colors.white);
      }
    }
    final me = Path()
      ..moveTo(c.dx, c.dy - 7)
      ..lineTo(c.dx + 5, c.dy + 5)
      ..lineTo(c.dx, c.dy + 2)
      ..lineTo(c.dx - 5, c.dy + 5)
      ..close();
    canvas.drawPath(me, Paint()..color = Colors.white);
    canvas.restore();
  }

  static math.Point<double> _pointAtS(RouteGeometry g, double s) {
    for (var i = 0; i < g.pts.length - 1; i++) {
      if (g.cum[i + 1] >= s) {
        final seg = g.cum[i + 1] - g.cum[i];
        final t = seg == 0 ? 0.0 : (s - g.cum[i]) / seg;
        final a = g.pts[i], b = g.pts[i + 1];
        return math.Point(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
      }
    }
    return g.pts.last;
  }

  @override
  bool shouldRepaint(MiniRoutePainter old) => old.v != v;
}
