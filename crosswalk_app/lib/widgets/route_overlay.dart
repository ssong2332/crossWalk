import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/ground_projection.dart';
import '../services/route_nav.dart';
import '../services/walk_info.dart';

/// T198: 카메라 화면 위 경로 층 — 바닥에 누운 셰브론 화살표(다음 회전까지 곧게,
/// 회전 방향으로 꺾임) + 위쪽 모서리의 작은 경로선 미니맵(배경 지도 없음).
///
/// 층 순서(오케스트레이터 조율 2026-11-24, 아래->위): 미리보기 -> 경계(T200) ->
/// **경로 화살표(여기)** -> 노란 면 -> 글자. 경로가 없으면 아무것도 그리지 않는다.
/// 색은 경계 전용 보라를 피하고 앱의 스틸·흰색 계열을 쓴다.
/// 음성으로 같은 안내가 나가므로 화면 읽기에서는 제외한다.
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
            final showArrow = v.alpha > 0 && !svc.onCrosswalk;
            return Stack(children: [
              if (showArrow)
                Positioned.fill(
                  child: CustomPaint(
                    painter: GroundRoutePainter(v.arrow, v.alpha),
                  ),
                ),
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

/// 지면 경로점을 [GroundProjection]으로 투영해 짧은 셰브론 조각으로 그린다.
class GroundRoutePainter extends CustomPainter {
  GroundRoutePainter(this.path, this.alpha,
      {this.projection = const GroundProjection()});
  final List<math.Point<double>> path;
  final double alpha;
  final GroundProjection projection;

  static const halfWidth = 0.5;

  @override
  void paint(Canvas canvas, Size size) {
    if (path.length < 2) return;
    final fill = Paint()
      ..color = RouteOverlay.steel.withValues(alpha: 0.85 * alpha);
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.white.withValues(alpha: 0.9 * alpha);
    // 6칸 그리고 4칸 비우기 -> 멀어질수록 촘촘한 셰브론.
    for (var i = 0; i + 6 < path.length; i += 10) {
      final poly = _ribbon(i, i + 6, size);
      if (poly == null) continue;
      final p = Path()..addPolygon(poly, true);
      canvas.drawPath(p, fill);
      canvas.drawPath(p, edge);
    }
    final head = _head(size);
    if (head != null) {
      final p = Path()..addPolygon(head, true);
      canvas.drawPath(p, fill..color = Colors.white.withValues(alpha: alpha));
    }
  }

  ({double x, double z}) _normal(int i) {
    final a = path[math.max(0, i - 1)];
    final b = path[math.min(path.length - 1, i + 1)];
    var dx = b.x - a.x, dz = b.y - a.y;
    final n = math.sqrt(dx * dx + dz * dz);
    if (n == 0) return (x: 1, z: 0);
    dx /= n;
    dz /= n;
    return (x: dz, z: -dx);
  }

  List<Offset>? _ribbon(int i0, int i1, Size size) {
    final left = <Offset>[], right = <Offset>[];
    for (var i = i0; i <= i1; i++) {
      final n = _normal(i);
      final l = projection.project(
          path[i].x - n.x * halfWidth, path[i].y - n.z * halfWidth, size);
      final r = projection.project(
          path[i].x + n.x * halfWidth, path[i].y + n.z * halfWidth, size);
      if (l == null || r == null) return null;
      left.add(l);
      right.add(r);
    }
    return [...left, ...right.reversed];
  }

  List<Offset>? _head(Size size) {
    final e = path.last;
    final d = path[math.max(0, path.length - 4)];
    var dx = e.x - d.x, dz = e.y - d.y;
    final n = math.sqrt(dx * dx + dz * dz);
    if (n == 0) return null;
    dx /= n;
    dz /= n;
    final pts = [
      projection.project(e.x + dx * 1.4, e.y + dz * 1.4, size),
      projection.project(e.x + dz * 1.2, e.y - dx * 1.2, size),
      projection.project(e.x - dz * 1.2, e.y + dx * 1.2, size),
    ];
    if (pts.any((p) => p == null)) return null;
    return pts.cast<Offset>();
  }

  @override
  bool shouldRepaint(GroundRoutePainter old) =>
      old.path != path || old.alpha != alpha;
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
