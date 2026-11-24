import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/route_nav.dart';
import '../services/walk_info.dart';

/// T204(사용자 결정 2026-11-24): 카메라 화면 왼쪽 위의 작은 경로선 미니맵(배경 지도
/// 없음). T198의 바닥 화살표는 T203에서 지웠고 미니맵만 되살렸다.
///
/// 층 순서(아래->위): 미리보기 -> **미니맵(여기)** -> 노란 면 -> 글자. 경로가 없으면
/// 아무것도 그리지 않는다. 음성으로 같은 안내가 나가므로 화면 읽기에서는 제외한다.
class RouteOverlay extends StatelessWidget {
  const RouteOverlay({super.key});

  static const steel = Color(0xFFA8CDE8);

  @override
  Widget build(BuildContext context) {
    final svc = WalkInfoService.instance;
    return ExcludeSemantics(
      child: IgnorePointer(
        child: ValueListenableBuilder<RouteView?>(
          valueListenable: svc.view,
          builder: (context, v, _) {
            if (v == null) return const SizedBox.shrink();
            return Stack(children: [
              Positioned(
                left: 12,
                top: MediaQuery.paddingOf(context).top + 8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 104,
                      height: 104,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: CustomPaint(painter: MiniRoutePainter(v)),
                    ),
                    if (v.caption != null)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        color: Colors.black.withValues(alpha: 0.6),
                        child: Text(v.caption!,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w700)),
                      ),
                  ],
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }
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
