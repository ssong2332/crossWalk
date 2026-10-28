// T104: 노면 안내 판정표(`docs/SurfaceGuidance.md`) — SurfaceGuide 순수 로직 테스트.
import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/services/surface_guide.dart';

SurfaceFeatures feat({
  SurfaceRegion front = const SurfaceRegion(),
  SurfaceRegion left = const SurfaceRegion(),
  SurfaceRegion right = const SurfaceRegion(),
}) =>
    SurfaceFeatures(left: left, front: front, right: right);

const sidewalk = SurfaceRegion(sidewalk: 1);
const road = SurfaceRegion(road: 1);
const onLinear = SurfaceRegion(sidewalk: 0.8, linear: 0.2);
const onDot = SurfaceRegion(sidewalk: 0.8, dot: 0.2);
const linearHere = SurfaceRegion(sidewalk: 0.8, linear: 0.2);

void main() {
  final t0 = DateTime(2026, 9, 30, 12);
  DateTime at(double s) => t0.add(Duration(milliseconds: (s * 1000).round()));

  /// [seq]를 0.5초 간격으로 넣고 (시각, 이벤트) 목록을 돌려준다.
  List<(double, SurfaceEvent)> run(SurfaceGuide g, List<SurfaceFeatures> seq,
      {String state = 'none', double start = 0}) {
    final out = <(double, SurfaceEvent)>[];
    for (var i = 0; i < seq.length; i++) {
      final t = start + i * 0.5;
      for (final e in g.update(seq[i], state, at(t))) {
        out.add((t, e));
      }
    }
    return out;
  }

  group('fromLogits — 아래 절반 3칸 비율', () {
    test('위 절반은 무시하고, 가로 3칸으로 나눈다', () {
      // 6클래스 × 4행 × 6열. 아래 2행: 왼쪽 2열 인도, 가운데 2열 선형, 오른쪽 2열 차도.
      List<List<double>> plane(int cls) => List.generate(4, (y) => List.generate(6, (x) {
            if (y < 2) return cls == SurfaceClass.road ? 9.0 : 0.0; // 위 절반은 전부 차도
            final want = x < 2
                ? SurfaceClass.sidewalk
                : (x < 4 ? SurfaceClass.linear : SurfaceClass.road);
            return cls == want ? 9.0 : 0.0;
          }));
      final f = SurfaceFeatures.fromLogits(
          List.generate(SurfaceClass.count, (c) => plane(c)));
      expect(f.left.sidewalk, 1.0);
      expect(f.front.linear, 1.0);
      expect(f.front.road, 0.0, reason: '위 절반의 차도는 세지 않는다');
      expect(f.right.road, 1.0);
    });

    // T105: 9클래스 모델의 주의 구역 비율, 그리고 6클래스 모델도 그대로 동작.
    List<List<double>> uniform(int cls, int want) =>
        List.generate(4, (_) => List.generate(6, (_) => cls == want ? 9.0 : 0.0));

    test('9클래스: 맨홀·그레이팅·가로수·계단 비율을 읽는다 (T105)', () {
      for (final (want, read) in [
        (SurfaceClass.manholeGrating, (SurfaceRegion r) => r.manholeGrating),
        (SurfaceClass.treeZone, (SurfaceRegion r) => r.treeZone),
        (SurfaceClass.stairs, (SurfaceRegion r) => r.stairs),
      ]) {
        final f = SurfaceFeatures.fromLogits(
            List.generate(SurfaceClass.count, (c) => uniform(c, want)));
        expect(read(f.front), 1.0, reason: '$want');
        expect(f.front.sidewalk, 0.0);
      }
    });

    test('T125: 횡단보도 비율 — 화면 전체(위 절반 포함)와 칸별', () {
      // 4행 × 6열. 위 2행: 가운데 2열 횡단보도. 아래 2행: 앞 칸 1열만 횡단보도, 나머지 인도.
      List<List<double>> plane(int cls) => List.generate(4, (y) => List.generate(6, (x) {
            final cw = y < 2 ? (x == 2 || x == 3) : x == 2;
            final want = cw ? SurfaceClass.crosswalk : SurfaceClass.sidewalk;
            return cls == want ? 9.0 : 0.0;
          }));
      final f = SurfaceFeatures.fromLogits(
          List.generate(SurfaceClass.count, (c) => plane(c)));
      expect(f.crosswalkAll, closeTo(6 / 24, 1e-9));
      expect(f.front.crosswalk, 0.5);
      expect(f.left.crosswalk, 0.0);
      expect(f.left.sidewalk, 1.0, reason: '아래 절반 칸 비율은 그대로');
    });

    test('6클래스 로짓도 동작한다 — 주의 구역 비율은 0 (T105)', () {
      final f = SurfaceFeatures.fromLogits(
          List.generate(6, (c) => uniform(c, SurfaceClass.sidewalk)));
      expect(f.front.sidewalk, 1.0);
      expect(f.front.manholeGrating, 0.0);
      expect(f.front.treeZone, 0.0);
    });
  });

  group('CautionGuide — 주의 구역 판정표 (docs/CautionGuidance.md, T105)', () {
    const manhole = SurfaceRegion(sidewalk: 0.8, manholeGrating: 0.15);
    const tree = SurfaceRegion(sidewalk: 0.8, treeZone: 0.15);
    const smallManhole = SurfaceRegion(sidewalk: 0.92, manholeGrating: 0.08);

    List<(double, CautionEvent)> runC(CautionGuide g, List<SurfaceFeatures> seq,
        {String state = 'none', double start = 0, bool surfaceFired = false}) {
      final out = <(double, CautionEvent)>[];
      for (var i = 0; i < seq.length; i++) {
        final t = start + i * 0.5;
        for (final e
            in g.update(seq[i], state, at(t), surfaceEventFired: surfaceFired)) {
          out.add((t, e));
        }
      }
      return out;
    }

    test('C1: 맨홀·그레이팅 10% 이상이 연속 2회면 1회, 머무는 동안 반복 없음', () {
      final ev = runC(CautionGuide(), List.filled(8, feat(front: manhole)));
      expect(ev, [(0.5, CautionEvent.manholeGrating)]);
    });

    test('C1: 10% 미만은 말하지 않는다', () {
      expect(runC(CautionGuide(), List.filled(8, feat(front: smallManhole))), isEmpty);
    });

    test('C2: 가로수 구역도 같은 방식', () {
      final ev = runC(CautionGuide(), List.filled(4, feat(front: tree)));
      expect(ev, [(0.5, CautionEvent.treeZone)]);
    });

    test('3초 안에 다시 나타나면 침묵, 3초 넘게 없다가 나타나면 다시 1회', () {
      final g = CautionGuide();
      runC(g, List.filled(3, feat(front: manhole)));
      // 2초 없음(재무장 안 됨) -> 다시 나타남: 침묵
      runC(g, List.filled(4, feat(front: sidewalk)), start: 1.5);
      expect(runC(g, List.filled(3, feat(front: manhole)), start: 3.5), isEmpty);
      // 4초 없음 -> 다시 나타남: 1회
      runC(g, List.filled(9, feat(front: sidewalk)), start: 5);
      expect(runC(g, List.filled(3, feat(front: manhole)), start: 9.5),
          [(10.0, CautionEvent.manholeGrating)]);
    });

    test('C3: 같은 판정에서 노면 안내(B)가 났으면 말하지 않고, 그 등장은 다시 말하지 않는다', () {
      final g = CautionGuide();
      expect(runC(g, List.filled(2, feat(front: manhole)), surfaceFired: true), isEmpty);
      expect(runC(g, List.filled(4, feat(front: manhole)), start: 1), isEmpty);
    });

    test('C5·C6·C7: approach·위·hold·무판정에서는 침묵', () {
      for (final st in ['approach', 'front', 'left', 'right', 'hold', 'nocall']) {
        expect(runC(CautionGuide(), List.filled(4, feat(front: manhole)), state: st),
            isEmpty,
            reason: st);
      }
    });

    test('crossed에서는 말한다', () {
      expect(
          runC(CautionGuide(), List.filled(2, feat(front: tree)), state: 'crossed'),
          [(0.5, CautionEvent.treeZone)]);
    });
  });

  group('상태 게이트 (판정표 4·9·10)', () {
    test('none/crossed에서만 말한다', () {
      expect(SurfaceGuide.isActiveState('none'), isTrue);
      expect(SurfaceGuide.isActiveState('crossed'), isTrue);
      for (final s in ['approach', 'front', 'left', 'right', 'hold', 'nocall', 'error']) {
        expect(SurfaceGuide.isActiveState(s), isFalse, reason: s);
      }
    });

    test('횡단보도 위에서는 차도가 보여도 침묵', () {
      final g = SurfaceGuide();
      expect(run(g, [feat(front: sidewalk), feat(front: sidewalk), ...List.filled(4, feat(front: road))],
          state: 'front'), isEmpty);
    });

    test('approach에서 멈춤 블록은 침묵(4번)', () {
      final g = SurfaceGuide();
      expect(run(g, List.filled(4, feat(front: onDot)), state: 'approach'), isEmpty);
    });
  });

  group('차도 (1·2번)', () {
    test('인도 -> 차도 전이는 road, 이어지면 3초마다 반복', () {
      final g = SurfaceGuide();
      final ev = run(g, [...List.filled(4, feat(front: sidewalk)), ...List.filled(10, feat(front: road))]);
      final times = ev.where((e) => e.$2 == SurfaceEvent.road).map((e) => e.$1).toList();
      // 차도 첫 장 2.0s, 연속 2회 확인은 2.5s. 이후 3초마다.
      expect(times, [2.5, 5.5]);
    });

    test('차도 1장짜리 오판에는 말하지 않는다(연속 2회 확인)', () {
      final g = SurfaceGuide();
      expect(run(g, [feat(front: sidewalk), feat(front: sidewalk), feat(front: road),
          feat(front: sidewalk), feat(front: sidewalk)]), isEmpty);
    });

    test('전이 없이 처음부터 차도면 1회만(Q1) — 반복하지 않는다', () {
      final g = SurfaceGuide();
      final ev = run(g, List.filled(12, feat(front: road)));
      expect(ev.map((e) => e.$2), [SurfaceEvent.road]);
    });

    test('차도가 3초 이상 안 보였다가 다시 나타나면 다시 1회(재무장)', () {
      final g = SurfaceGuide();
      const other = SurfaceRegion(); // 배경 — 인도도 차도도 아님
      final ev = run(g, [
        ...List.filled(3, feat(front: road)),
        ...List.filled(8, feat(front: other)), // 4초
        ...List.filled(3, feat(front: road)),
      ]);
      expect(ev.where((e) => e.$2 == SurfaceEvent.road).length, 2);
    });
  });

  group('멈춤 블록 (3번)', () {
    test('처음 나타나면 1회, 머무는 동안 반복 없음', () {
      final g = SurfaceGuide();
      final ev = run(g, [feat(front: sidewalk), ...List.filled(8, feat(front: onDot))]);
      expect(ev.map((e) => e.$2), [SurfaceEvent.dotBlock]);
    });

    test('3초 안에 다시 나타나면 침묵, 3초 넘게 없다가 나타나면 다시 1회', () {
      final g = SurfaceGuide();
      final ev = run(g, [
        ...List.filled(3, feat(front: onDot)),
        ...List.filled(3, feat(front: sidewalk)), // 1.5초 없음
        ...List.filled(3, feat(front: onDot)),
        ...List.filled(9, feat(front: sidewalk)), // 4.5초 없음
        ...List.filled(3, feat(front: onDot)),
      ]);
      expect(ev.where((e) => e.$2 == SurfaceEvent.dotBlock).length, 2);
    });
  });

  group('선형 (5~8번)', () {
    test('올라서면 linearOn(진동만), 오른쪽으로 벗어나면 linearRight', () {
      final g = SurfaceGuide();
      final ev = run(g, [
        ...List.filled(3, feat(front: onLinear)),
        ...List.filled(3, feat(front: sidewalk, right: linearHere)),
      ]);
      expect(ev.map((e) => e.$2), [SurfaceEvent.linearOn, SurfaceEvent.linearRight]);
    });

    test('왼쪽으로 벗어나면 linearLeft', () {
      final g = SurfaceGuide();
      final ev = run(g, [
        ...List.filled(3, feat(front: onLinear)),
        ...List.filled(3, feat(front: sidewalk, left: linearHere)),
      ]);
      expect(ev.last.$2, SurfaceEvent.linearLeft);
    });

    test('세 칸 모두 선형이 2초 이상 없으면 linearLost 1회', () {
      final g = SurfaceGuide();
      final ev = run(g, [
        ...List.filled(3, feat(front: onLinear)),
        ...List.filled(10, feat(front: sidewalk)),
      ]);
      expect(ev.map((e) => e.$2), [SurfaceEvent.linearOn, SurfaceEvent.linearLost]);
    });

    test('T148: 앞 칸 선형 15% 미만이면 linearOn 없음, 15% 이상이면 있음', () {
      expect(SurfaceGuide.linearOnRatio, 0.15);
      const thin = SurfaceRegion(sidewalk: 0.9, linear: 0.10);
      const edge = SurfaceRegion(sidewalk: 0.85, linear: 0.15);
      expect(run(SurfaceGuide(), List.filled(6, feat(front: thin))), isEmpty);
      expect(run(SurfaceGuide(), List.filled(3, feat(front: edge))).map((e) => e.$2),
          [SurfaceEvent.linearOn]);
    });

    test('선형 위에 한 번도 없었으면 옆 선형만으로는 말하지 않는다', () {
      final g = SurfaceGuide();
      expect(run(g, List.filled(6, feat(front: sidewalk, right: linearHere))), isEmpty);
    });
  });

  test('비활성 상태를 거치면 상태가 비워진다(옛 인도 기록으로 전이 판정 안 함)', () {
    final g = SurfaceGuide();
    run(g, List.filled(4, feat(front: sidewalk)));
    run(g, [feat(front: sidewalk)], state: 'front', start: 2);
    // 다시 none: 인도 기록이 비워졌으므로 차도는 '처음 1회'(전이 아님) — 반복 없음.
    final ev = run(g, List.filled(12, feat(front: road)), start: 2.5);
    expect(ev.map((e) => e.$2), [SurfaceEvent.road]);
  });
}
