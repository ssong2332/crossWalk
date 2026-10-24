import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../services/score_timeline.dart';

/// T129: 시안 D "촉각 악보" — 디버그 상자 자리에서 음성·대기·만료·진동을
/// **실제 시각 기준으로** 오른쪽(지금)에서 왼쪽(과거)으로 흘려 그린다.
/// 화면 녹화만 보고도 "무엇을 말하는 중이고 무엇이 대기 중인지" 읽히는 것이 목적.
///
/// 켜져 있는 동안만 매 프레임 다시 그린다(Ticker). 모션 줄이기(`disableAnimations`)면
/// 1초에 한 번만 다시 그린다 — 흐름 대신 계단식으로 넘어간다.
class HapticScoreView extends StatefulWidget {
  const HapticScoreView({
    super.key,
    required this.timeline,
    required this.reducedMotion,
    this.clock = DateTime.now,
  });

  final ScoreTimeline timeline;
  final bool reducedMotion;

  /// 테스트용 시계.
  final DateTime Function() clock;

  /// 그림 높이(글자 두 줄은 별도).
  static const canvasHeight = 132.0;

  @override
  State<HapticScoreView> createState() => _HapticScoreViewState();
}

class _HapticScoreViewState extends State<HapticScoreView>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant HapticScoreView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reducedMotion != widget.reducedMotion) _sync();
  }

  void _sync() {
    _ticker?.dispose();
    _ticker = null;
    _timer?.cancel();
    _timer = null;
    if (widget.reducedMotion) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _ticker = createTicker((_) {
        if (mounted) setState(() {});
      })
        ..start();
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.clock();
    final t = widget.timeline;
    final speaking = t.speaking;
    final waiting = t.pending.map((p) {
      final s = now.difference(p.since).inMilliseconds / 1000;
      return '${p.deferred ? '보류' : '대기'} ${s.toStringAsFixed(1)}s ${p.text}';
    }).join(' / ');
    final speakingLine = speaking == null
        ? '말하는 중: —'
        : '말하는 중: ${speaking.text}'
            '${speaking.rate != null ? ' ×${speaking.rate}' : ''}'
            ' (${(now.difference(speaking.start).inMilliseconds / 1000).toStringAsFixed(1)}s)';
    final waitingLine = waiting.isEmpty ? '대기: —' : waiting;

    return Semantics(
      label: '$speakingLine. $waitingLine',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(speakingLine,
                key: const ValueKey('score-speaking'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: ScorePainter.speechColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
            Text(waitingLine,
                key: const ValueKey('score-waiting'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: t.pending.isEmpty
                        ? ScorePainter.labelColor
                        : ScorePainter.pendingColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            SizedBox(
              height: HapticScoreView.canvasHeight,
              child: CustomPaint(
                painter: ScorePainter(timeline: t, now: now),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 네 줄(음성·대기·진동·위치) 시간축. 오른쪽 끝이 지금, 왼쪽 끝이 [span] 전.
class ScorePainter extends CustomPainter {
  ScorePainter({required this.timeline, required this.now})
      : _revision = timeline.revision;

  final ScoreTimeline timeline;
  final DateTime now;
  final int _revision;

  static const span = Duration(seconds: 8);
  static const gutter = 34.0;

  // 배경 #0E1013 대비(계산값): 하늘 9.9:1, 앰버 9.6:1, 회색 7.4:1.
  static const speechColor = Color(0xFFA8CDE8);
  static const pendingColor = Color(0xFFF2B14A);
  static const buzzColor = Color(0xFFF2B14A);
  static const labelColor = Color(0xFFA9B0B6);
  static const alertColor = Color(0xFFFF5A5F);
  static const lineColor = Color(0xFF2A2F35);
  static const ink = Color(0xFF08182A);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width - gutter;
    if (w <= 0) return;
    final rowH = size.height / 4;
    final spanMs = span.inMilliseconds.toDouble();
    double x(DateTime t) =>
        gutter + w * (1 - now.difference(t).inMilliseconds / spanMs);

    final line = Paint()..color = lineColor;
    for (var r = 1; r < 4; r++) {
      canvas.drawRect(Rect.fromLTWH(0, rowH * r, size.width, 1), line);
    }
    // 1초 눈금
    for (var s = 1; s < span.inSeconds; s++) {
      final gx = gutter + w * (1 - s / span.inSeconds);
      canvas.drawRect(Rect.fromLTWH(gx, 0, 1, size.height), line);
    }
    const names = ['음성', '대기', '진동', '위치'];
    for (var r = 0; r < 4; r++) {
      _text(canvas, names[r], Offset(0, rowH * r + rowH / 2 - 7),
          labelColor, 11, gutter - 2);
    }

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(gutter, 0, w, size.height));

    // 상태 경계 — 네 줄을 가로지르는 세로선 + 위쪽에 상태 이름.
    for (final m in timeline.marks) {
      if (m.kind != ScoreMarkKind.state) continue;
      final mx = x(m.at);
      canvas.drawRect(Rect.fromLTWH(mx, 0, 1.5, size.height),
          Paint()..color = labelColor.withValues(alpha: 0.5));
      _text(canvas, m.text, Offset(mx + 2, rowH * 3 + 1), labelColor, 9, 60);
    }

    // 음성: 말한 구간 막대 + 문장. 끊김·오류는 끝을 빨갛게.
    for (final s in timeline.speech) {
      final x0 = x(s.start);
      final x1 = x(s.end ?? now);
      final r = Rect.fromLTRB(x0, 3, x1 < x0 + 2 ? x0 + 2 : x1, rowH - 3);
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(3)),
          Paint()..color = speechColor);
      _text(canvas, s.text, Offset(x0 + 3, 5), ink, 11, 400);
      if (!s.open && s.result != 'done') {
        canvas.drawRect(Rect.fromLTWH(r.right - 3, r.top, 3, r.height),
            Paint()..color = alertColor);
      }
    }
    // 대기: 들어온 때부터 지금까지 테두리 막대(지금도 기다리는 중).
    for (final p in timeline.pending) {
      final r = Rect.fromLTRB(x(p.since), rowH + 3, x(now), rowH * 2 - 3);
      canvas.drawRect(
          r,
          Paint()
            ..color = pendingColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
      _text(canvas, p.text, Offset(r.left + 3, rowH + 5), pendingColor, 11, 400);
    }
    // 만료·취소·버림: 그 시각에 표시.
    for (final m in timeline.marks) {
      if (m.kind == ScoreMarkKind.state) continue;
      final mx = x(m.at);
      final label = switch (m.kind) {
        ScoreMarkKind.ttl => '만료',
        ScoreMarkKind.cancel => '취소',
        _ => '버림',
      };
      final rowTop = m.kind == ScoreMarkKind.drop ? 0.0 : rowH;
      canvas.drawRect(
          Rect.fromLTWH(mx - 1, rowTop + 2, 3, rowH - 4), Paint()..color = alertColor);
      _text(canvas, '$label ${m.text}', Offset(mx + 4, rowTop + rowH - 14),
          alertColor, 9, 160);
    }
    // 진동: 켜짐 구간.
    final buzz = Paint()..color = buzzColor;
    for (final b in timeline.buzzes) {
      final x0 = x(b.start);
      final x1 = x(b.end);
      canvas.drawRect(
          Rect.fromLTRB(x0, rowH * 2 + 5, x1 < x0 + 2 ? x0 + 2 : x1, rowH * 3 - 5),
          buzz);
    }
    // 위치: -2(왼쪽 끝) ~ +2(오른쪽 끝). 가운데 점선 대신 얇은 선.
    final mid = rowH * 3.5;
    canvas.drawRect(Rect.fromLTWH(gutter, mid, w, 1),
        Paint()..color = labelColor.withValues(alpha: 0.4));
    final dot = Paint()..color = speechColor;
    for (final p in timeline.positions) {
      final py = mid - (p.value.clamp(-2.0, 2.0) / 2) * (rowH / 2 - 3);
      canvas.drawCircle(Offset(x(p.at), py), 2.2, dot);
    }
    // 지금 선
    canvas.restore();
    canvas.drawRect(Rect.fromLTWH(size.width - 2, 0, 2, size.height),
        Paint()..color = const Color(0xFFF1F3F4));
  }

  void _text(Canvas canvas, String s, Offset at, Color color, double size,
      double maxWidth) {
    final tp = TextPainter(
      text: TextSpan(
          text: s,
          style: TextStyle(
              color: color, fontSize: size, fontWeight: FontWeight.w700)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant ScorePainter oldDelegate) =>
      oldDelegate.now != now || oldDelegate._revision != _revision;
}
