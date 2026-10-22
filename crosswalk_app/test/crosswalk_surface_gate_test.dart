// T125: 노면 횡단보도 확인 판정표(`docs/SurfaceGuidance.md` §T125) — 순수 로직 테스트.
import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/services/crosswalk_surface_gate.dart';

void main() {
  final t0 = DateTime(2026, 10, 21, 17);
  DateTime at(double s) => t0.add(Duration(milliseconds: (s * 1000).round()));

  /// [ratios]를 0.4초 간격(실기기 노면 간격 약 0.41초)으로 넣는다. 마지막 시각을 돌려준다.
  double feed(CrosswalkSurfaceGate g, List<double> ratios, {double start = 0}) {
    var t = start;
    for (final r in ratios) {
      g.note(r, at(t));
      t += 0.4;
    }
    return t - 0.4;
  }

  test('1행: 꺼짐이면 approach 그대로, 평가하지 않는다(기존 동작)', () {
    final g = CrosswalkSurfaceGate();
    final last = feed(g, [0, 0, 0, 0, 0]);
    final r = g.apply('approach', enabled: false, now: at(last));
    expect(r.label, 'approach');
    expect(r.verdict, isNull);
  });

  test('2행: approach가 아니면 건드리지 않는다 (위 판정은 범위 밖)', () {
    final g = CrosswalkSurfaceGate();
    final last = feed(g, [0, 0, 0]);
    for (final label in ['none', 'front', 'left', 'right', 'crossed']) {
      final r = g.apply(label, enabled: true, now: at(last));
      expect(r.label, label);
      expect(r.verdict, isNull, reason: label);
    }
  });

  test('3행: 노면 판정이 없으면(노면 모델 꺼짐) 적용 불가 — approach 유지', () {
    final g = CrosswalkSurfaceGate();
    final r = g.apply('approach', enabled: true, now: at(0));
    expect(r.label, 'approach');
    expect(r.verdict, 'na');
    expect(r.maxRatio, isNull);
  });

  test('3행: 마지막 노면 판정이 2.5초보다 오래되면 적용 불가', () {
    final g = CrosswalkSurfaceGate();
    final last = feed(g, [0, 0, 0]);
    final r = g.apply('approach', enabled: true, now: at(last + 2.6));
    expect(r.label, 'approach');
    expect(r.verdict, 'na');
  });

  test('5행: 켜짐 + 횡단보도 비율 0 → none', () {
    final g = CrosswalkSurfaceGate();
    final last = feed(g, [0, 0, 0, 0, 0]);
    final r = g.apply('approach', enabled: true, now: at(last));
    expect(r.label, 'none');
    expect(r.verdict, 'drop');
    expect(r.maxRatio, 0);
    expect(r.samples, 5);
  });

  test('5행: 1% 바로 아래(0.009)도 none', () {
    final g = CrosswalkSurfaceGate();
    final last = feed(g, [0.009, 0.005]);
    expect(g.apply('approach', enabled: true, now: at(last)).label, 'none');
  });

  test('4행: 켜짐 + 횡단보도 비율 >= 1% → approach 유지', () {
    final g = CrosswalkSurfaceGate();
    final last = feed(g, [0.01]);
    final r = g.apply('approach', enabled: true, now: at(last));
    expect(r.label, 'approach');
    expect(r.verdict, 'keep');
  });

  test('4행: 최근 5개 중 하나만 >= 1%여도 유지 (최대값)', () {
    final g = CrosswalkSurfaceGate();
    final last = feed(g, [0, 0.3, 0, 0, 0]);
    final r = g.apply('approach', enabled: true, now: at(last));
    expect(r.label, 'approach');
    expect(r.maxRatio, 0.3);
  });

  test('창은 마지막 5개 — 6개 전의 횡단보도는 잊는다', () {
    final g = CrosswalkSurfaceGate();
    final last = feed(g, [0.5, 0, 0, 0, 0, 0]);
    final r = g.apply('approach', enabled: true, now: at(last));
    expect(r.label, 'none');
    expect(r.samples, 5);
  });

  test('창 안이라도 2.5초 넘은 판정은 뺀다', () {
    final g = CrosswalkSurfaceGate();
    g.note(0.5, at(0));
    g.note(0, at(2.0));
    final r = g.apply('approach', enabled: true, now: at(2.6));
    expect(r.label, 'none');
    expect(r.samples, 1);
  });

  test('reset 뒤에는 적용 불가', () {
    final g = CrosswalkSurfaceGate();
    final last = feed(g, [0, 0]);
    g.reset();
    expect(g.apply('approach', enabled: true, now: at(last)).verdict, 'na');
  });
}
