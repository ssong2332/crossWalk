/// T200: 횡단보도 경계 표시(C안, 사용자 승인 2026-11-24) — 노면 모델의 횡단보도 구간에서
/// 화면에 그릴 영역과 **보이는** 양 끝 경계 직선을 만든다. 순수 Dart라 테스트할 수 있다.
///
/// 설계: `train/t200/mockup.html` 3·6절, 시안 스크립트 `train/t200/mockup.py`(같은 규칙).
///
/// 상태별 표시 판정표([outlineModeFor]):
///   | 상태                         | 표시                                   |
///   | front / left / right (횡단 중) | full: 칠하기 25% + 보이는 경계선 + 위치 막대 |
///   | approach                     | fillOnly: 칠하기 12%만                  |
///   | 그 외(none·crossed·nocall·error) | hidden: 그리지 않음 (경로 화살표와 경쟁 안 함) |
///
/// 경계선을 그리지 않는 경우(틀린 선을 덜 그리기 위해):
///   - 횡단보도가 발 앞(격자 아래 [reachFraction])까지 오지 않음 → 접근 중, 양쪽 다 생략
///   - 그 쪽 선이 화면 테두리에서 [edgeMargin] 칸 안 → 경계가 화면 밖, 그 쪽만 생략
/// 알려진 한계: 차 등이 가린 선을 경계로 오인한다(시안 3행) — 개발·동행자 확인용이라 기본 꺼짐.
library;

enum OutlineMode { hidden, fillOnly, full }

OutlineMode outlineModeFor(String fieldState) {
  switch (fieldState) {
    case 'front':
    case 'left':
    case 'right':
      return OutlineMode.full;
    case 'approach':
      return OutlineMode.fillOnly;
    default:
      return OutlineMode.hidden;
  }
}

/// 격자 좌표의 직선 x = a*y + b.
class EdgeLine {
  const EdgeLine(this.a, this.b);
  final double a;
  final double b;
  double xAt(double y) => a * y + b;
}

class CrosswalkOutline {
  const CrosswalkOutline({
    required this.rows,
    required this.gridWidth,
    required this.yTop,
    required this.yBottom,
    this.left,
    this.right,
  });

  /// 칠할 행 구간 `[시작0, 끝0, ...]`(가장 긴 세로 덩어리만, 나머지 행은 -1).
  final List<int> rows;
  final int gridWidth;
  int get gridHeight => rows.length ~/ 2;
  final int yTop;
  final int yBottom;

  /// null이면 그 쪽 경계는 그리지 않는다(화면 밖이거나 접근 중).
  final EdgeLine? left;
  final EdgeLine? right;

  /// 한 행에 이보다 짧은 구간은 잡음으로 본다(시안과 같음).
  static const minRunPixels = 6;
  static const minRows = 12;

  /// 행이 이만큼 비어도 같은 덩어리로 본다.
  static const maxRowGap = 3;
  static const edgeMargin = 4;
  static const reachFraction = 200 / 224;

  /// [rows]는 `SurfaceFeatures.crosswalkRows`. 덩어리가 작으면 null.
  static CrosswalkOutline? fromRows(List<int> rows, int gridWidth) {
    final h = rows.length ~/ 2;
    if (h == 0 || gridWidth == 0) return null;
    bool valid(int y) =>
        rows[2 * y] >= 0 && rows[2 * y + 1] - rows[2 * y] + 1 >= minRunPixels;

    // 아래에서 위로, 위아래 행 구간이 겹치는 행끼리 묶어 가장 많은 행을 가진 덩어리를 고른다.
    var best = <int>[];
    var cur = <int>[];
    for (var y = h - 1; y >= 0; y--) {
      if (!valid(y)) {
        if (cur.isNotEmpty && cur.last - y > maxRowGap) {
          if (cur.length > best.length) best = cur;
          cur = <int>[];
        }
        continue;
      }
      if (cur.isNotEmpty) {
        final p = cur.last;
        final overlaps = rows[2 * y] <= rows[2 * p + 1] && rows[2 * y + 1] >= rows[2 * p];
        if (!overlaps || p - y > maxRowGap + 1) {
          if (cur.length > best.length) best = cur;
          cur = <int>[];
        }
      }
      cur.add(y);
    }
    if (cur.length > best.length) best = cur;
    if (best.length < minRows) return null;

    final kept = List<int>.filled(2 * h, -1);
    for (final y in best) {
      kept[2 * y] = rows[2 * y];
      kept[2 * y + 1] = rows[2 * y + 1];
    }
    final ys = [for (final y in best) y.toDouble()];
    final yTop = best.last;
    final yBottom = best.first;
    EdgeLine? left = _fit(ys, [for (final y in best) rows[2 * y].toDouble()]);
    EdgeLine? right = _fit(ys, [for (final y in best) rows[2 * y + 1].toDouble()]);

    if (yBottom < reachFraction * h) {
      left = null;
      right = null;
    } else {
      final lMin = [left.xAt(yTop.toDouble()), left.xAt(yBottom.toDouble())]
          .reduce((a, b) => a < b ? a : b);
      final rMax = [right.xAt(yTop.toDouble()), right.xAt(yBottom.toDouble())]
          .reduce((a, b) => a > b ? a : b);
      if (lMin <= edgeMargin) left = null;
      if (rMax >= gridWidth - 1 - edgeMargin) right = null;
    }
    return CrosswalkOutline(
        rows: kept,
        gridWidth: gridWidth,
        yTop: yTop,
        yBottom: yBottom,
        left: left,
        right: right);
  }

  /// 최소제곱 직선, 잔차 상위 20%를 한 번 버리고 다시 맞춘다(시안 `edges`와 같음).
  static EdgeLine _fit(List<double> ys, List<double> xs) {
    var line = _lsq(ys, xs);
    final res = [for (var i = 0; i < ys.length; i++) (line.xAt(ys[i]) - xs[i]).abs()];
    final sorted = [...res]..sort();
    final cut = sorted[((sorted.length - 1) * 0.8).floor()];
    final ky = <double>[], kx = <double>[];
    for (var i = 0; i < ys.length; i++) {
      if (res[i] <= cut) {
        ky.add(ys[i]);
        kx.add(xs[i]);
      }
    }
    if (ky.length >= 2) line = _lsq(ky, kx);
    return line;
  }

  static EdgeLine _lsq(List<double> ys, List<double> xs) {
    final n = ys.length;
    var sy = 0.0, sx = 0.0, syy = 0.0, sxy = 0.0;
    for (var i = 0; i < n; i++) {
      sy += ys[i];
      sx += xs[i];
      syy += ys[i] * ys[i];
      sxy += ys[i] * xs[i];
    }
    final d = n * syy - sy * sy;
    if (d.abs() < 1e-9) return EdgeLine(0, sx / n);
    final a = (n * sxy - sy * sx) / d;
    return EdgeLine(a, (sx - a * sy) / n);
  }
}

/// 노면 모델은 약 2.5Hz(11/22 기록 간격 중앙 400ms)라 선이 툭툭 바뀐다 — 직선 계수를
/// 지수 평활하고, 한두 번 놓쳐도 바로 지우지 않는다. 칠하기 구간은 최신 값 그대로.
class CrosswalkOutlineSmoother {
  CrosswalkOutlineSmoother({this.alpha = 0.5, this.holdMisses = 2});

  /// 새 값 비중.
  final double alpha;

  /// 연속으로 이만큼 놓치면 지운다.
  final int holdMisses;

  CrosswalkOutline? _last;
  int _misses = 0;

  CrosswalkOutline? add(CrosswalkOutline? next) {
    if (next == null) {
      _misses++;
      if (_misses >= holdMisses) _last = null;
      return _last;
    }
    _misses = 0;
    final prev = _last;
    EdgeLine? mix(EdgeLine? p, EdgeLine? n) => p == null || n == null
        ? n
        : EdgeLine(p.a + alpha * (n.a - p.a), p.b + alpha * (n.b - p.b));
    _last = prev == null
        ? next
        : CrosswalkOutline(
            rows: next.rows,
            gridWidth: next.gridWidth,
            yTop: next.yTop,
            yBottom: next.yBottom,
            left: mix(prev.left, next.left),
            right: mix(prev.right, next.right));
    return _last;
  }

  void reset() {
    _last = null;
    _misses = 0;
  }
}
