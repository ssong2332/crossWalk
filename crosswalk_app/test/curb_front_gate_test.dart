// T138: 연석 '위' 오판 막기 판정표(`curb_front_gate.dart`) — 순수 로직 테스트.
import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/services/curb_front_gate.dart';
import 'package:crosswalk_app/services/surface_guide.dart';

void main() {
  final t0 = DateTime(2026, 10, 26, 21, 34);
  DateTime at(double s) => t0.add(Duration(milliseconds: (s * 1000).round()));

  // 10/26 #1 연석(맨 아래 1/6 줄 오프라인 값 예: 인도+블록 0.34, 횡단보도 0.11).
  const curb = FootSurface(ground: 0.34, crosswalk: 0.11);
  // 실제 횡단 중(횡단보도 1.0).
  const stripes = FootSurface(ground: 0, crosswalk: 1.0);
  // 가려진·검은 화면(배경만).
  const dark = FootSurface(ground: 0, crosswalk: 0);

  /// [feet]를 0.4초 간격으로 넣는다. 마지막 시각을 돌려준다.
  double feed(CurbFrontGate g, List<FootSurface> feet, {double start = 0}) {
    var t = start;
    for (final f in feet) {
      g.note(f, at(t));
      t += 0.4;
    }
    return t - 0.4;
  }

  test('1행: 설정 꺼짐이면 위 그대로', () {
    final g = CurbFrontGate();
    final last = feed(g, [curb, curb]);
    final r = g.apply('front', current: 'approach', enabled: false, now: at(last));
    expect(r.label, 'front');
    expect(r.dropped, isFalse);
  });

  test('2행: 분류 라벨이 위가 아니면 그대로', () {
    final g = CurbFrontGate();
    final last = feed(g, [curb, curb]);
    for (final label in ['none', 'approach', 'crossed']) {
      final r = g.apply(label, current: 'approach', enabled: true, now: at(last));
      expect(r.label, label, reason: label);
      expect(r.dropped, isFalse, reason: label);
    }
  });

  test('3행: 이미 건너는 중(위·hold)이면 그대로 — hold·발밑 인도 해제와 겹치지 않음', () {
    final g = CurbFrontGate();
    final last = feed(g, [curb, curb]);
    for (final current in ['front', 'left', 'right', 'hold']) {
      final r = g.apply('left', current: current, enabled: true, now: at(last));
      expect(r.label, 'left', reason: current);
      expect(r.dropped, isFalse, reason: current);
    }
  });

  test('4행: 최근 2개가 모두 연석(횡단보도 < 0.5, 인도+블록 >= 0.1)이면 approach', () {
    for (final current in ['approach', 'none', 'crossed']) {
      final g = CurbFrontGate();
      final last = feed(g, [curb, curb]);
      final r = g.apply('front', current: current, enabled: true, now: at(last));
      expect(r.label, 'approach', reason: current);
      expect(r.dropped, isTrue, reason: current);
      expect(r.samples, hasLength(2));
      expect(r.samples.first.crosswalk, 0.11);
    }
  });

  test('4행: left/right도 같다', () {
    final g = CurbFrontGate();
    final last = feed(g, [curb, curb]);
    for (final label in ['left', 'right']) {
      final r = g.apply(label, current: 'approach', enabled: true, now: at(last));
      expect(r.label, 'approach', reason: label);
    }
  });

  test('4행 경계: 횡단보도 0.5면 내리지 않고, 인도+블록 0.1이면 내린다', () {
    final g1 = CurbFrontGate();
    final l1 = feed(g1, const [
      FootSurface(ground: 0.3, crosswalk: 0.5),
      FootSurface(ground: 0.3, crosswalk: 0.5),
    ]);
    expect(g1.apply('front', current: 'approach', enabled: true, now: at(l1)).label,
        'front');
    final g2 = CurbFrontGate();
    final l2 = feed(g2, const [
      FootSurface(ground: 0.1, crosswalk: 0.49),
      FootSurface(ground: 0.1, crosswalk: 0.49),
    ]);
    expect(g2.apply('front', current: 'approach', enabled: true, now: at(l2)).label,
        'approach');
  });

  test('5행: 발밑이 줄무늬면 그대로(실제 진입)', () {
    final g = CurbFrontGate();
    final last = feed(g, [stripes, stripes]);
    final r = g.apply('front', current: 'approach', enabled: true, now: at(last));
    expect(r.label, 'front');
    expect(r.dropped, isFalse);
  });

  test('5행: 가려진·검은 화면(인도+블록 < 0.1)은 내리지 않는다(보수안)', () {
    final g = CurbFrontGate();
    final last = feed(g, [dark, dark]);
    expect(g.apply('front', current: 'approach', enabled: true, now: at(last)).label,
        'front');
  });

  test('5행: 2개 중 하나만 연석이면 그대로', () {
    final g = CurbFrontGate();
    final last = feed(g, [stripes, curb]);
    expect(g.apply('front', current: 'approach', enabled: true, now: at(last)).label,
        'front');
  });

  test('5행: 노면 판정이 1개뿐이거나 없으면 그대로', () {
    final g = CurbFrontGate();
    expect(g.apply('front', current: 'approach', enabled: true, now: at(0)).label,
        'front');
    g.note(curb, at(0));
    expect(g.apply('front', current: 'approach', enabled: true, now: at(0)).label,
        'front');
  });

  test('5행: 2.5초보다 오래된 판정은 쓰지 않는다', () {
    final g = CurbFrontGate();
    final last = feed(g, [curb, curb]);
    expect(
        g.apply('front', current: 'approach', enabled: true, now: at(last + 2.2)).label,
        'front'); // 첫 판정이 2.6초 전 — 2.5초를 넘음
    expect(g.apply('front', current: 'approach', enabled: true, now: at(last + 2.0)).label,
        'approach');
  });

  test('창은 최근 2개만 — 줄무늬 뒤 연석 2개면 내린다, reset하면 비운다', () {
    final g = CurbFrontGate();
    final last = feed(g, [stripes, curb, curb]);
    expect(g.apply('front', current: 'approach', enabled: true, now: at(last)).label,
        'approach');
    g.reset();
    expect(g.apply('front', current: 'approach', enabled: true, now: at(last)).label,
        'front');
  });

  group('FootSurface.fromLogits: 맨 아래 1/6 줄, 전체 폭', () {
    /// 12줄 × 3칸 로짓. [cls]가 (y, x)의 최고 클래스.
    List logitsOf(int Function(int y, int x) cls, {int h = 12, int w = 3}) => [
          for (var c = 0; c < SurfaceClass.count; c++)
            [
              for (var y = 0; y < h; y++)
                [for (var x = 0; x < w; x++) cls(y, x) == c ? 1.0 : 0.0]
            ]
        ];

    test('위쪽 줄은 세지 않는다(12줄이면 마지막 2줄만)', () {
      // 0~9줄 횡단보도, 10~11줄 인도.
      final f = FootSurface.fromLogits(
          logitsOf((y, x) => y < 10 ? SurfaceClass.crosswalk : SurfaceClass.sidewalk));
      expect(f.ground, 1.0);
      expect(f.crosswalk, 0.0);
    });

    test('인도+선형+점형을 합치고, 횡단보도를 따로 센다', () {
      // 마지막 2줄 × 3칸 = 6칸: 인도·선형·점형·횡단보도·차도·배경.
      const order = [
        SurfaceClass.sidewalk,
        SurfaceClass.linear,
        SurfaceClass.dot,
        SurfaceClass.crosswalk,
        SurfaceClass.road,
        SurfaceClass.background,
      ];
      final f = FootSurface.fromLogits(
          logitsOf((y, x) => y < 10 ? SurfaceClass.crosswalk : order[(y - 10) * 3 + x]));
      expect(f.ground, closeTo(3 / 6, 1e-9));
      expect(f.crosswalk, closeTo(1 / 6, 1e-9));
    });

    test('224줄이면 187~223줄(37줄)을 본다', () {
      final f = FootSurface.fromLogits(logitsOf(
          (y, x) => y >= 187 ? SurfaceClass.sidewalk : SurfaceClass.crosswalk,
          h: 224,
          w: 2));
      expect(f.ground, 1.0);
      expect(f.crosswalk, 0.0);
    });
  });
}
