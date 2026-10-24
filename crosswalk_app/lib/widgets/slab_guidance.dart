import 'package:flutter/material.dart';

/// T129: 시안 A "큰 글씨 슬랩" — 저시력 사용자가 남은 시력으로 1초 안에
/// "어느 쪽으로"를 읽게 하는 화면 표현. 판정·음성·진동은 건드리지 않는다.
///
/// 이탈 단계가 오를수록 **가야 할 쪽**에서 노란 면이 밀려 들어와 넓어진다:
///
/// | 상태 | 단계 | 노란 면 | 위험 막대 |
/// |---|---|---|---|
/// | left/right 이탈 | 보통 | 0% | 없음 |
/// | left/right 이탈 | 즉시(severe) | 가야 할 쪽 62% | 없음 |
/// | left/right 이탈 | 가장자리(atEdge) | 100% | 벗어난 쪽 가장자리 |
/// | 그 외 | — | 0% | 없음 |
///
/// 색에만 기대지 않는다: 단계는 면의 **넓이**(0/62/100%)와 위험 막대의 **유무**,
/// 방향은 면이 붙는 **쪽**과 큰 글자("왼쪽으로"), 관측 문구("오른쪽 끝")로 겹쳐 전한다.
enum SlabLevel { none, mild, severe, edge }

enum SlabSide { left, right }

/// 노란 면 색. 검정 글자와 대비 14.9:1(계산값).
///
/// 야간 눈부심은 실기기로 확인하지 않은 추정 위험이다 — 밝기를 낮춰야 하면
/// [SlabBackdrop.color]에 더 어두운 노랑(예: 0xFFC9A800, 검정 대비 약 9:1)을
/// 넘기면 된다. 글자는 검정이라 어두운 노랑에서도 AA를 지킨다.
const Color kSlabYellow = Color(0xFFFFD60A);
const Color kSlabInk = Color(0xFF000000);

@immutable
class SlabSpec {
  const SlabSpec(this.level, this.goSide);

  static const none = SlabSpec(SlabLevel.none, null);

  /// 화면 상태(`left`=왼쪽으로 틀어짐 → 오른쪽으로 가야 함)에서 표현을 정한다.
  /// 단계 판단은 화면 제목과 같은 순서다: 끝(atEdge)이 강도(severe)보다 먼저.
  factory SlabSpec.from(String fieldState,
      {required bool severe, required bool atEdge}) {
    final SlabSide side;
    if (fieldState == 'left') {
      side = SlabSide.right;
    } else if (fieldState == 'right') {
      side = SlabSide.left;
    } else {
      return none;
    }
    final level = atEdge
        ? SlabLevel.edge
        : severe
            ? SlabLevel.severe
            : SlabLevel.mild;
    return SlabSpec(level, side);
  }

  final SlabLevel level;

  /// 가야 할 쪽. 이탈이 아니면 null.
  final SlabSide? goSide;

  /// 노란 면이 덮는 화면 너비 비율.
  double get coverage => switch (level) {
        SlabLevel.severe => 0.62,
        SlabLevel.edge => 1.0,
        _ => 0.0,
      };

  /// 글자·화살표가 노란 면 위에 놓이는가(그러면 검정 잉크).
  bool get onSlab => coverage > 0;

  bool get deviating => goSide != null;

  /// 위험 막대 쪽 = 벗어난 쪽 = 가야 할 쪽의 반대. 가장자리에서만.
  SlabSide? get hazardSide => level != SlabLevel.edge
      ? null
      : goSide == SlabSide.left
          ? SlabSide.right
          : SlabSide.left;

  @override
  bool operator ==(Object other) =>
      other is SlabSpec && other.level == level && other.goSide == goSide;

  @override
  int get hashCode => Object.hash(level, goSide);
}

/// 화면 전체 높이의 노란 면 + 가장자리 위험 막대. 장식이라 읽지 않는다.
class SlabBackdrop extends StatefulWidget {
  const SlabBackdrop({
    super.key,
    required this.spec,
    required this.reducedMotion,
    this.pulse,
    this.color = kSlabYellow,
  });

  final SlabSpec spec;

  /// `MediaQuery.disableAnimations` — 켜져 있으면 면이 즉시 바뀌고 막대는 고정 밝기.
  final bool reducedMotion;

  /// 위험 막대 밝기를 흔드는 0..1 반복 애니메이션(reverse). 주기는 호출자가
  /// 정한다 — 밝기 변화가 초당 3회를 넘지 않게(WCAG 2.3.1).
  final Animation<double>? pulse;

  final Color color;

  static const slideDuration = Duration(milliseconds: 550);
  static const hazardWidth = 28.0;

  @override
  State<SlabBackdrop> createState() => _SlabBackdropState();
}

class _SlabBackdropState extends State<SlabBackdrop> {
  // 면이 걷힐 때도 붙어 있던 쪽으로 물러나도록 마지막 쪽을 기억한다.
  SlabSide _side = SlabSide.left;

  @override
  void initState() {
    super.initState();
    _side = widget.spec.goSide ?? _side;
  }

  @override
  void didUpdateWidget(covariant SlabBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    _side = widget.spec.goSide ?? _side;
  }

  @override
  Widget build(BuildContext context) {
    final duration =
        widget.reducedMotion ? Duration.zero : SlabBackdrop.slideDuration;
    final hazard = widget.spec.hazardSide;
    return ExcludeSemantics(
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final total = constraints.maxWidth;
            final width = total * widget.spec.coverage;
            return Stack(
              children: [
                AnimatedPositioned(
                  key: const ValueKey('slab-surface'),
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  top: 0,
                  bottom: 0,
                  left: _side == SlabSide.left ? 0 : total - width,
                  width: width,
                  child: ColoredBox(color: widget.color),
                ),
                if (hazard != null)
                  Positioned(
                    key: const ValueKey('slab-hazard'),
                    top: 0,
                    bottom: 0,
                    left: hazard == SlabSide.left
                        ? 0
                        : total - SlabBackdrop.hazardWidth,
                    width: SlabBackdrop.hazardWidth,
                    child: _hazard(),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _hazard() {
    final bar = CustomPaint(painter: HazardStripePainter(widget.color));
    final pulse = widget.pulse;
    if (pulse == null || widget.reducedMotion) return bar;
    return FadeTransition(
      opacity: pulse.drive(
          Tween<double>(begin: 0.35, end: 1).chain(CurveTween(curve: Curves.easeInOut))),
      child: bar,
    );
  }
}

/// 검정·노랑 사선 줄무늬(공사장 위험 표시).
class HazardStripePainter extends CustomPainter {
  const HazardStripePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = kSlabInk);
    final p = Paint()..color = color;
    const step = 28.0;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (var y = -size.width; y < size.height + size.width; y += step) {
      final path = Path()
        ..moveTo(0, y)
        ..lineTo(size.width, y - size.width)
        ..lineTo(size.width, y - size.width + step / 2)
        ..lineTo(0, y + step / 2)
        ..close();
      canvas.drawPath(path, p);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant HazardStripePainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 큰 글자 한 줄 + 작은 관측 문구. 노란 면이 62%면 그 안에만 놓인다.
///
/// 읽기(TalkBack)는 [semanticsLabel] 한 덩어리 — 화면 글자 배치와 무관하게
/// 이전과 같은 문장("오른쪽으로 크게 벗어남. 왼쪽으로")을 라이브 영역으로 낸다.
class SlabHeadline extends StatelessWidget {
  const SlabHeadline({
    super.key,
    required this.spec,
    required this.bigText,
    required this.smallText,
    required this.semanticsLabel,
    required this.color,
    required this.reducedMotion,
    this.backing,
    this.dimColor = const Color(0xFFF1F3F4),
    this.slabColor = kSlabYellow,
  });

  final SlabSpec spec;
  final String bigText;
  final String smallText;
  final String semanticsLabel;

  /// 면 밖, 이탈이 아닐 때의 큰 글자 색.
  final Color color;
  final Color dimColor;
  final Color slabColor;
  final bool reducedMotion;

  /// 카메라 프리뷰 위일 때 글자 뒤에 깔 불투명 배경(대비 보장). 면 위에선 쓰지 않는다.
  final Color? backing;

  static const bigFontSize = 84.0;

  Color get inkColor => spec.onSlab
      ? kSlabInk
      : spec.deviating
          ? slabColor
          : color;

  @override
  Widget build(BuildContext context) {
    final side = spec.goSide;
    final alignRight = side == SlabSide.right;
    final ink = inkColor;
    final small = spec.onSlab ? kSlabInk : dimColor;
    final duration =
        reducedMotion ? Duration.zero : const Duration(milliseconds: 280);

    Widget content = Column(
      crossAxisAlignment:
          alignRight ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSwitcher(
          duration: duration,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: animation.drive(Tween<Offset>(
                  begin: const Offset(0, 0.15), end: Offset.zero)),
              child: child,
            ),
          ),
          child: FittedBox(
            key: ValueKey(bigText),
            fit: BoxFit.scaleDown,
            alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
            child: Text(
              bigText,
              maxLines: 1,
              style: TextStyle(
                color: ink,
                fontSize: bigFontSize,
                height: 1.05,
                fontWeight: FontWeight.w900,
                letterSpacing: -2,
              ),
            ),
          ),
        ),
        if (smallText.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              smallText,
              textAlign: alignRight ? TextAlign.right : TextAlign.left,
              style: TextStyle(
                color: small,
                fontSize: 22,
                height: 1.25,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    );

    // 가장자리에선 위험 막대(28)가 화면 끝에 서므로, 바깥 여백(20)만으로는 큰
    // 글자가 막대 밑으로 들어간다 — 그쪽만 더 띄운다.
    final hazard = spec.hazardSide;
    if (hazard != null) {
      const extra = SlabBackdrop.hazardWidth - 20 + 8;
      content = Padding(
        padding: hazard == SlabSide.left
            ? const EdgeInsets.only(left: extra)
            : const EdgeInsets.only(right: extra),
        child: content,
      );
    }

    final back = backing;
    if (back != null && !spec.onSlab) {
      content = DecoratedBox(
        decoration: BoxDecoration(
          color: back,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: content,
        ),
      );
    }

    return Semantics(
      liveRegion: true,
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: SizedBox(
          width: double.infinity,
          child: Align(
            alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: spec.level == SlabLevel.severe ? spec.coverage : 1.0,
              alignment:
                  alignRight ? Alignment.centerRight : Alignment.centerLeft,
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}
