import 'package:crosswalk_app/services/crosswalk_outline.dart';
import 'package:crosswalk_app/services/surface_guide.dart';
import 'package:flutter_test/flutter_test.dart';

/// 224x224 격자에서 행 [y0, y1) 구간을 [xAt(y)] 왼/오른 끝으로 채운 행 구간 목록.
List<int> rowsOf(int y0, int y1, int Function(int y) l, int Function(int y) r,
    {int h = 224}) {
  final rows = List<int>.filled(2 * h, -1);
  for (var y = y0; y < y1; y++) {
    rows[2 * y] = l(y);
    rows[2 * y + 1] = r(y);
  }
  return rows;
}

void main() {
  group('상태별 표시 판정표 (outlineModeFor)', () {
    const table = {
      'front': OutlineMode.full,
      'left': OutlineMode.full,
      'right': OutlineMode.full,
      'approach': OutlineMode.fillOnly,
      'none': OutlineMode.hidden,
      'crossed': OutlineMode.hidden,
      'nocall': OutlineMode.hidden,
      'error': OutlineMode.hidden,
    };
    table.forEach((state, mode) {
      test('$state → $mode', () => expect(outlineModeFor(state), mode));
    });
  });

  group('경계 직선 맞추기', () {
    test('곧은 사각형: 양쪽 선이 x=40, x=179', () {
      final o = CrosswalkOutline.fromRows(rowsOf(60, 224, (_) => 40, (_) => 179), 224)!;
      expect(o.yTop, 60);
      expect(o.yBottom, 223);
      expect(o.left!.a, closeTo(0, 1e-9));
      expect(o.left!.b, closeTo(40, 1e-9));
      expect(o.right!.xAt(100), closeTo(179, 1e-9));
    });

    test('원근 사다리꼴: 기울기를 맞춘다', () {
      // 왼쪽 x = 100 - 0.4y, 오른쪽 x = 120 + 0.4y (아래로 갈수록 넓어짐)
      final o = CrosswalkOutline.fromRows(
          rowsOf(40, 224, (y) => (100 - 0.4 * y).round(), (y) => (120 + 0.4 * y).round()),
          224)!;
      expect(o.left!.a, closeTo(-0.4, 0.02));
      expect(o.right!.a, closeTo(0.4, 0.02));
    });

    test('튀는 행 몇 개(20% 이하)는 버리고 맞춘다', () {
      final rows = rowsOf(60, 224, (_) => 40, (_) => 179);
      for (final y in [70, 90, 110]) {
        rows[2 * y] = 10; // 잡음
      }
      final o = CrosswalkOutline.fromRows(rows, 224)!;
      expect(o.left!.b, closeTo(40, 1.0));
    });

    test('떨어진 작은 덩어리는 무시하고 큰 덩어리만 쓴다', () {
      final rows = rowsOf(60, 224, (_) => 40, (_) => 179);
      for (var y = 0; y < 8; y++) {
        rows[2 * y] = 0;
        rows[2 * y + 1] = 10;
      }
      final o = CrosswalkOutline.fromRows(rows, 224)!;
      expect(o.yTop, 60);
      expect(o.rows[0], -1);
    });

    test('행이 모자라면 null', () {
      expect(CrosswalkOutline.fromRows(rowsOf(200, 210, (_) => 40, (_) => 179), 224), isNull);
      expect(CrosswalkOutline.fromRows(List<int>.filled(448, -1), 224), isNull);
    });
  });

  group('화면 밖 경계·접근 중은 선을 그리지 않는다', () {
    test('왼쪽이 화면 테두리에 붙음 → 오른쪽 선만', () {
      final o = CrosswalkOutline.fromRows(rowsOf(60, 224, (_) => 0, (_) => 150), 224)!;
      expect(o.left, isNull);
      expect(o.right, isNotNull);
    });

    test('양쪽 다 화면 밖 → 선 없음(칠하기만)', () {
      final o = CrosswalkOutline.fromRows(rowsOf(60, 224, (_) => 0, (_) => 223), 224)!;
      expect(o.left, isNull);
      expect(o.right, isNull);
      expect(o.rows[2 * 100], 0);
    });

    test('발 앞까지 안 옴(접근 중) → 선 없음', () {
      final o = CrosswalkOutline.fromRows(rowsOf(40, 120, (_) => 20, (_) => 200), 224)!;
      expect(o.left, isNull);
      expect(o.right, isNull);
    });
  });

  group('평활', () {
    test('선 계수를 반씩 섞고, 두 번 연속 놓치면 지운다', () {
      final s = CrosswalkOutlineSmoother();
      s.add(CrosswalkOutline.fromRows(rowsOf(60, 224, (_) => 40, (_) => 179), 224));
      final m = s.add(CrosswalkOutline.fromRows(rowsOf(60, 224, (_) => 60, (_) => 179), 224))!;
      expect(m.left!.b, closeTo(50, 1e-6));
      expect(s.add(null), isNotNull);
      expect(s.add(null), isNull);
    });

    test('한쪽 선이 새로 보이면 섞지 않고 새 값', () {
      final s = CrosswalkOutlineSmoother();
      s.add(CrosswalkOutline.fromRows(rowsOf(60, 224, (_) => 0, (_) => 179), 224));
      final m = s.add(CrosswalkOutline.fromRows(rowsOf(60, 224, (_) => 40, (_) => 179), 224))!;
      expect(m.left!.b, closeTo(40, 1e-6));
    });
  });

  test('SurfaceFeatures.fromLogits가 행마다 가장 긴 횡단보도 구간을 낸다', () {
    // 9클래스 x 4행 x 10열: 횡단보도(3)를 행 2의 x 1~2, 5~8에 둔다 → 긴 쪽 5~8.
    final logits = List.generate(
        SurfaceClass.count,
        (c) => List.generate(
            4,
            (y) => List.generate(10, (x) {
                  final cw = y == 2 && ((x >= 1 && x <= 2) || (x >= 5 && x <= 8));
                  if (c == SurfaceClass.crosswalk) return cw ? 5.0 : 0.0;
                  return c == SurfaceClass.road ? 1.0 : 0.0;
                })));
    final f = SurfaceFeatures.fromLogits(logits);
    expect(f.gridWidth, 10);
    expect(f.crosswalkRows.sublist(4, 6), [5, 8]);
    expect(f.crosswalkRows.sublist(0, 2), [-1, -1]);
  });
}
