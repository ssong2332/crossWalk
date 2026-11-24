import 'package:flutter/material.dart';

import '../services/crosswalk_outline.dart';
import '../services/direction_resolver.dart';

/// T200: 횡단보도 경계 표시 층(카메라 미리보기 바로 위, T198 경로 화살표 아래).
///
/// 색은 보라 하나 — 앱 화살표 색(스틸·앰버·심함 빨강·노란 면)과 겹치지 않게 골랐다.
/// 끝 구간은 색이 아니라 **두께·이중선·고리**로 알린다(빨강은 '심한 이탈' 전용).
///
/// 좌표: 노면 모델 격자는 세로 카메라 프레임 **전체**를 누른 것이다. 미리보기는
/// `_buildFullBleedPreview`처럼 화면을 꽉 채우게(cover) 확대되므로 같은 변환을 쓴다.
class CrosswalkOutlinePainter extends CustomPainter {
  const CrosswalkOutlinePainter({
    required this.outline,
    required this.mode,
    required this.camAspect,
    this.position,
    this.barY = 0.72,
  });

  static const violet = Color(0xFFB58CFF);

  final CrosswalkOutline? outline;
  final OutlineMode mode;

  /// 세로 카메라 프레임의 너비/높이(= 1 / controller.value.aspectRatio).
  final double camAspect;

  /// 평활된 위치(-2 왼쪽 끝 ~ +2 오른쪽 끝). null이면 막대를 그리지 않는다.
  final double? position;

  /// 위치 막대 높이(화면 높이 비율). 아래 판독부(불투명)에 가리지 않게 위로 올렸다 —
  /// 실기기에서 화살표 꼬리와 겹치는지는 확인 필요(추정값).
  final double barY;

  /// 격자 (gx, gy) → 화면 좌표.
  Offset toScreen(double gx, double gy, Size size) {
    final o = outline!;
    final boxAspect = size.width / size.height;
    final dw = camAspect >= boxAspect ? size.height * camAspect : size.width;
    final dh = camAspect >= boxAspect ? size.height : size.width / camAspect;
    return Offset(size.width / 2 + (gx / o.gridWidth - 0.5) * dw,
        size.height / 2 + (gy / o.gridHeight - 0.5) * dh);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final o = outline;
    if (o == null || mode == OutlineMode.hidden || size.isEmpty) return;
    final full = mode == OutlineMode.full;

    final fill = Path();
    for (var y = 0; y < o.gridHeight; y++) {
      final s = o.rows[2 * y];
      if (s < 0) continue;
      fill.addRect(Rect.fromPoints(toScreen(s.toDouble(), y.toDouble(), size),
          toScreen(o.rows[2 * y + 1] + 1.0, y + 1.0, size)));
    }
    canvas.drawPath(
        fill, Paint()..color = violet.withValues(alpha: full ? 0.25 : 0.12));
    if (!full) return;

    final p = position;
    final near = p == null
        ? 0
        : (p <= -DirectionResolver.edgePosition
            ? -1
            : (p >= DirectionResolver.edgePosition ? 1 : 0));
    void edge(EdgeLine? l, bool hot) {
      if (l == null) return;
      final a = toScreen(l.xAt(o.yTop.toDouble()), o.yTop.toDouble(), size);
      final b = toScreen(l.xAt(o.yBottom + 1.0), o.yBottom + 1.0, size);
      Paint stroke(Color c, double w) => Paint()
        ..color = c
        ..strokeWidth = w
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(a, b, stroke(Colors.black, hot ? 13 : 9));
      canvas.drawLine(a, b, stroke(violet, hot ? 9 : 5));
      if (hot) canvas.drawLine(a, b, stroke(Colors.black, 2)); // 이중선
    }

    edge(o.left, near == -1);
    edge(o.right, near == 1);

    if (p == null) return;
    final y = size.height * barY;
    final x0 = size.width * 0.15, x1 = size.width * 0.85;
    canvas.drawLine(Offset(x0, y), Offset(x1, y),
        Paint()
          ..color = Colors.black
          ..strokeWidth = 12);
    canvas.drawLine(Offset(x0, y), Offset(x1, y),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 6);
    for (final f in const [0.25, 0.75]) {
      // 끝 판정선 ±1.0 (위치 -2~+2에서 25%·75%)
      final x = x0 + f * (x1 - x0);
      canvas.drawLine(Offset(x, y - 14), Offset(x, y + 14),
          Paint()
            ..color = Colors.black
            ..strokeWidth = 4);
    }
    final px = x0 + (p.clamp(-2.0, 2.0) + 2) / 4 * (x1 - x0);
    canvas.drawCircle(Offset(px, y), 13, Paint()..color = Colors.black);
    canvas.drawCircle(Offset(px, y), 9, Paint()..color = Colors.white);
    if (near != 0) {
      canvas.drawCircle(
          Offset(px, y),
          17,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3);
    }
  }

  @override
  bool shouldRepaint(covariant CrosswalkOutlinePainter old) =>
      old.outline != outline ||
      old.mode != mode ||
      old.camAspect != camAspect ||
      old.position != position ||
      old.barY != barY;
}
