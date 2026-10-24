import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/widgets/slab_guidance.dart';

// T129: 시안 A "큰 글씨 슬랩" — 단계 표(SlabSpec)와 노란 면·위험 막대·큰 글자.
void main() {
  group('SlabSpec.from — 단계 표', () {
    test('왼쪽으로 틀어짐(left) → 오른쪽으로 가야 함', () {
      final s = SlabSpec.from('left', severe: false, atEdge: false);
      expect(s.goSide, SlabSide.right);
      expect(s.level, SlabLevel.mild);
      expect(s.coverage, 0);
      expect(s.hazardSide, isNull);
    });

    test('즉시(severe)는 가야 할 쪽 62%', () {
      final s = SlabSpec.from('right', severe: true, atEdge: false);
      expect(s.goSide, SlabSide.left);
      expect(s.level, SlabLevel.severe);
      expect(s.coverage, 0.62);
      expect(s.onSlab, isTrue);
      expect(s.hazardSide, isNull);
    });

    test('가장자리는 100%, 위험 막대는 벗어난 쪽', () {
      final s = SlabSpec.from('right', severe: false, atEdge: true);
      expect(s.level, SlabLevel.edge);
      expect(s.coverage, 1.0);
      expect(s.hazardSide, SlabSide.right);
      final l = SlabSpec.from('left', severe: false, atEdge: true);
      expect(l.hazardSide, SlabSide.left);
    });

    test('끝(atEdge)이 강도(severe)보다 먼저 — 화면 제목과 같은 순서', () {
      expect(SlabSpec.from('left', severe: true, atEdge: true).level,
          SlabLevel.edge);
    });

    test('이탈이 아니면 면 없음', () {
      for (final state in [
        'front',
        'approach',
        'none',
        'crossed',
        'nocall',
        'hold',
        'loading',
        'error'
      ]) {
        expect(SlabSpec.from(state, severe: true, atEdge: true), SlabSpec.none,
            reason: state);
      }
    });
  });

  group('SlabBackdrop', () {
    Widget host(SlabSpec spec, {bool reduced = false, Animation<double>? pulse}) =>
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 400,
              height: 800,
              child: SlabBackdrop(spec: spec, reducedMotion: reduced, pulse: pulse),
            ),
          ),
        );

    Rect surface(WidgetTester tester) =>
        tester.getRect(find.byKey(const ValueKey('slab-surface')));
    double surfaceLeft(WidgetTester tester) =>
        surface(tester).left - tester.getTopLeft(find.byType(SlabBackdrop)).dx;

    testWidgets('보통에서 즉시로 오르면 가야 할 쪽에서 62%까지 밀려 들어온다',
        (tester) async {
      const mild = SlabSpec(SlabLevel.mild, SlabSide.left);
      const severe = SlabSpec(SlabLevel.severe, SlabSide.left);
      await tester.pumpWidget(host(mild));
      expect(surface(tester).width, 0);
      await tester.pumpWidget(host(severe));
      await tester.pump(const Duration(milliseconds: 100));
      final mid = surface(tester).width;
      expect(mid, greaterThan(0));
      expect(mid, lessThan(248));
      await tester.pumpAndSettle();
      expect(surface(tester).width, closeTo(248, 0.01));
      expect(surfaceLeft(tester), closeTo(0, 0.01));
    });

    testWidgets('오른쪽으로 가야 하면 면이 오른쪽에 붙는다', (tester) async {
      await tester.pumpWidget(
          host(const SlabSpec(SlabLevel.severe, SlabSide.right), reduced: true));
      expect(surface(tester).width, closeTo(248, 0.01));
      expect(surfaceLeft(tester), closeTo(400 - 248, 0.01));
    });

    testWidgets('모션 줄이기면 즉시 바뀐다', (tester) async {
      await tester.pumpWidget(host(SlabSpec.none, reduced: true));
      await tester.pumpWidget(
          host(const SlabSpec(SlabLevel.edge, SlabSide.left), reduced: true));
      await tester.pump();
      expect(surface(tester).width, closeTo(400, 0.01));
    });

    testWidgets('가장자리에서만 위험 막대 — 벗어난 쪽 가장자리에', (tester) async {
      await tester.pumpWidget(
          host(const SlabSpec(SlabLevel.severe, SlabSide.left), reduced: true));
      expect(find.byKey(const ValueKey('slab-hazard')), findsNothing);
      // 가야 할 쪽 = 왼쪽 → 벗어난 쪽 = 오른쪽
      await tester.pumpWidget(
          host(const SlabSpec(SlabLevel.edge, SlabSide.left), reduced: true));
      final bar = tester.getRect(find.byKey(const ValueKey('slab-hazard')));
      final origin = tester.getTopLeft(find.byType(SlabBackdrop)).dx;
      expect(bar.width, SlabBackdrop.hazardWidth);
      expect(bar.right - origin, closeTo(400, 0.01));
    });

    testWidgets('위험 막대 밝기 흔들기는 모션 줄이기면 없다', (tester) async {
      final controller = AnimationController(
          vsync: const TestVSync(), duration: const Duration(milliseconds: 900));
      addTearDown(controller.dispose);
      const edge = SlabSpec(SlabLevel.edge, SlabSide.right);
      Finder fade() => find.descendant(
          of: find.byKey(const ValueKey('slab-hazard')),
          matching: find.byType(FadeTransition));
      await tester.pumpWidget(host(edge, pulse: controller));
      expect(fade(), findsOneWidget);
      await tester.pumpWidget(host(edge, pulse: controller, reduced: true));
      expect(fade(), findsNothing);
    });

    testWidgets('면은 장식 — 읽기 대상이 아니다', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
          host(const SlabSpec(SlabLevel.edge, SlabSide.right), reduced: true));
      expect(find.byType(ExcludeSemantics), findsWidgets);
      handle.dispose();
    });
  });

  group('SlabHeadline', () {
    Widget host(SlabSpec spec, {String big = '왼쪽으로', String small = '오른쪽 끝'}) =>
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              child: SlabHeadline(
                spec: spec,
                bigText: big,
                smallText: small,
                semanticsLabel: '오른쪽 끝. 왼쪽으로',
                color: const Color(0xFFA8CDE8),
                reducedMotion: true,
              ),
            ),
          ),
        );

    Color bigColor(WidgetTester tester, String text) =>
        tester.widget<Text>(find.text(text)).style!.color!;

    testWidgets('면 위면 검정, 보통 이탈이면 노랑, 그 외는 상태 색', (tester) async {
      await tester.pumpWidget(host(const SlabSpec(SlabLevel.edge, SlabSide.left)));
      expect(bigColor(tester, '왼쪽으로'), kSlabInk);
      await tester.pumpWidget(host(const SlabSpec(SlabLevel.mild, SlabSide.left)));
      expect(bigColor(tester, '왼쪽으로'), kSlabYellow);
      await tester.pumpWidget(host(SlabSpec.none, big: '직진', small: ''));
      expect(bigColor(tester, '직진'), const Color(0xFFA8CDE8));
    });

    testWidgets('즉시(62%)면 글자도 면 안에만 놓인다', (tester) async {
      await tester
          .pumpWidget(host(const SlabSpec(SlabLevel.severe, SlabSide.right)));
      final box = tester.widget<FractionallySizedBox>(find.descendant(
          of: find.byType(SlabHeadline),
          matching: find.byType(FractionallySizedBox)));
      expect(box.widthFactor, 0.62);
      expect(box.alignment, Alignment.centerRight);
    });

    testWidgets('가장자리면 위험 막대 쪽 글자를 막대 밖으로 띄운다', (tester) async {
      // 가야 할 쪽 = 오른쪽 → 막대는 왼쪽 끝. 바깥 여백 20 가정 시 막대(28) 밖 +8.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SlabHeadline(
              spec: const SlabSpec(SlabLevel.edge, SlabSide.right),
              bigText: '오른쪽으로',
              smallText: '왼쪽 끝',
              semanticsLabel: '왼쪽 끝. 오른쪽으로',
              color: const Color(0xFFA8CDE8),
              reducedMotion: true,
            ),
          ),
        ),
      ));
      final left = tester.getTopLeft(find.text('오른쪽으로')).dx;
      expect(left, greaterThanOrEqualTo(SlabBackdrop.hazardWidth + 8 - 0.01));
    });

    testWidgets('라이브 영역 한 덩어리로 읽힌다', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host(const SlabSpec(SlabLevel.mild, SlabSide.left)));
      expect(tester.getSemantics(find.bySemanticsLabel('오른쪽 끝. 왼쪽으로')),
          containsSemantics(isLiveRegion: true));
      expect(find.bySemanticsLabel('왼쪽으로'), findsNothing,
          reason: '큰 글자는 따로 읽지 않는다');
      handle.dispose();
    });
  });
}
