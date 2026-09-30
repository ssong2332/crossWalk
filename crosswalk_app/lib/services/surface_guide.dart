/// T104: 노면 안내 판정 — `docs/SurfaceGuidance.md` 판정표(사용자 확정 2026-09-30)의 구현.
///
/// 분할 모델(`SurfaceEstimator`) 결과의 **아래 절반**을 가로 3칸(왼쪽/앞/오른쪽)으로
/// 나눠 클래스별 면적 비율을 읽고, 판정표 규칙으로 안내 이벤트를 낸다. 순수 Dart라
/// 플랫폼 채널 없이 테스트할 수 있다. 시간은 인자로 주입한다.
///
/// 판정표 요약(번호는 문서의 행):
///   | #   | 조건 (연속 2회 확인 후)                              | 이벤트        |
///   | 1   | 직전 3초 안에 앞 인도 많음 -> 앞 차도 많음(전이)       | road (+3초마다) |
///   | 2   | 전이 없이 앞 차도 많음 — 재무장 후 처음 1회            | road          |
///   | 3   | 앞 점형 없음 -> 있음 (3초 없었다가 다시 나타나야 재무장) | dotBlock      |
///   | 5   | 앞 선형 없음 -> 있음                                  | linearOn      |
///   | 6·7 | 앞 선형이었다가 앞 없음 + 오른쪽/왼쪽 선형 있음         | linearRight/Left |
///   | 8   | 앞 선형이었다가 세 칸 모두 선형 없음이 2초 이상          | linearLost    |
///   | 4·9·10 | 분류기 상태가 none/crossed가 아님(approach·위·hold·무판정) | 없음(상태 초기화) |
/// 기준값(50%, 5%, 2회, 3초, 2초)은 추정이다 — 문서 §6.
library;

/// 모델 클래스 번호(`train/train_seg_t104.py`와 같다).
class SurfaceClass {
  SurfaceClass._();
  static const background = 0;
  static const sidewalk = 1;
  static const road = 2;
  static const crosswalk = 3;
  static const linear = 4;
  static const dot = 5;
  static const count = 6;
}

enum SurfaceEvent { road, dotBlock, linearOn, linearRight, linearLeft, linearLost }

/// 한 칸(영역)의 클래스별 면적 비율(0~1).
class SurfaceRegion {
  const SurfaceRegion(
      {this.sidewalk = 0, this.road = 0, this.linear = 0, this.dot = 0});

  final double sidewalk;
  final double road;
  final double linear;
  final double dot;

  @override
  String toString() => '인도 ${_p(sidewalk)} 차도 ${_p(road)} '
      '선형 ${_p(linear)} 점형 ${_p(dot)}';

  static String _p(double v) => (v * 100).toStringAsFixed(0);
}

class SurfaceFeatures {
  const SurfaceFeatures(
      {this.left = const SurfaceRegion(),
      this.front = const SurfaceRegion(),
      this.right = const SurfaceRegion()});

  final SurfaceRegion left;
  final SurfaceRegion front;
  final SurfaceRegion right;

  /// 모델 출력 로짓 `[클래스][세로][가로]`(배치 차원 제거)에서 아래 절반만 argmax해
  /// 세 칸의 비율을 낸다. 크기는 리스트 길이에서 읽는다.
  static SurfaceFeatures fromLogits(List logits) {
    final nCls = logits.length;
    final h = (logits[0] as List).length;
    final w = ((logits[0] as List)[0] as List).length;
    final counts = List.generate(3, (_) => List<int>.filled(SurfaceClass.count, 0));
    final totals = List<int>.filled(3, 0);
    for (var y = h ~/ 2; y < h; y++) {
      final rows = [for (var c = 0; c < nCls; c++) (logits[c] as List)[y] as List];
      for (var x = 0; x < w; x++) {
        var best = 0;
        var bestV = (rows[0][x] as num).toDouble();
        for (var c = 1; c < nCls; c++) {
          final v = (rows[c][x] as num).toDouble();
          if (v > bestV) {
            bestV = v;
            best = c;
          }
        }
        final region = x < w ~/ 3 ? 0 : (x < 2 * w ~/ 3 ? 1 : 2);
        if (best < SurfaceClass.count) counts[region][best]++;
        totals[region]++;
      }
    }
    SurfaceRegion r(int i) {
      final t = totals[i] == 0 ? 1 : totals[i];
      return SurfaceRegion(
        sidewalk: counts[i][SurfaceClass.sidewalk] / t,
        road: counts[i][SurfaceClass.road] / t,
        linear: counts[i][SurfaceClass.linear] / t,
        dot: counts[i][SurfaceClass.dot] / t,
      );
    }

    return SurfaceFeatures(left: r(0), front: r(1), right: r(2));
  }
}

/// 같은 값이 2번 연속일 때만 바뀌는 불리언(판정표 §2 연속 확인).
class _Debounced {
  bool value = false;
  bool? _cand;
  int _n = 0;

  /// 값이 이번에 바뀌었으면 true.
  bool update(bool x) {
    if (x == value) {
      _cand = null;
      _n = 0;
      return false;
    }
    if (x == _cand) {
      _n++;
    } else {
      _cand = x;
      _n = 1;
    }
    if (_n >= 2) {
      value = x;
      _cand = null;
      _n = 0;
      return true;
    }
    return false;
  }
}

class SurfaceGuide {
  static const manyRatio = 0.5;
  static const presentRatio = 0.05;
  static const transitionWindow = Duration(seconds: 3);
  static const rearmAfter = Duration(seconds: 3);
  static const roadRepeat = Duration(seconds: 3);
  static const lostAfter = Duration(seconds: 2);

  /// 노면 안내가 말할 수 있는 분류기 상태(판정표 §2 모드).
  static bool isActiveState(String state) => state == 'none' || state == 'crossed';

  _Debounced _side = _Debounced();
  _Debounced _road = _Debounced();
  _Debounced _dot = _Debounced();
  _Debounced _linFront = _Debounced();
  DateTime? _lastSideAt;
  DateTime? _roadOffSince;
  DateTime? _dotOffSince;
  bool _roadArmed = true;
  bool _dotArmed = true;
  bool _roadTransition = false;
  DateTime? _roadLastSpokenAt;
  bool _onLine = false;
  DateTime? _lostSince;

  void reset() {
    _side = _Debounced();
    _road = _Debounced();
    _dot = _Debounced();
    _linFront = _Debounced();
    _lastSideAt = null;
    _roadOffSince = null;
    _dotOffSince = null;
    _roadArmed = true;
    _dotArmed = true;
    _roadTransition = false;
    _roadLastSpokenAt = null;
    _onLine = false;
    _lostSince = null;
  }

  /// 분할 결과 하나를 넣고 이번에 낼 이벤트를 돌려준다(보통 0~1개).
  /// [state]는 화면의 현재 상태(`none`/`approach`/`front`/`left`/`right`/
  /// `crossed`/`hold`/`nocall`).
  List<SurfaceEvent> update(SurfaceFeatures f, String state, DateTime now) {
    if (!isActiveState(state)) {
      reset();
      return const [];
    }
    final out = <SurfaceEvent>[];
    final front = f.front;

    // 1·2: 차도.
    _side.update(front.sidewalk >= manyRatio);
    if (_side.value) _lastSideAt = now;
    final roadChanged = _road.update(front.road >= manyRatio);
    if (_road.value) {
      _roadOffSince = null;
      if (roadChanged) {
        final recentSide =
            _lastSideAt != null && now.difference(_lastSideAt!) <= transitionWindow;
        if (recentSide) {
          _roadTransition = true;
          _roadLastSpokenAt = now;
          out.add(SurfaceEvent.road);
        } else if (_roadArmed) {
          _roadLastSpokenAt = now;
          out.add(SurfaceEvent.road);
        }
        _roadArmed = false;
      } else if (_roadTransition &&
          _roadLastSpokenAt != null &&
          now.difference(_roadLastSpokenAt!) >= roadRepeat) {
        _roadLastSpokenAt = now;
        out.add(SurfaceEvent.road);
      }
    } else {
      _roadTransition = false;
      _roadOffSince ??= now;
      if (now.difference(_roadOffSince!) >= rearmAfter) _roadArmed = true;
    }

    // 3: 멈춤 블록.
    if (_dot.update(front.dot >= presentRatio) && _dot.value && _dotArmed) {
      out.add(SurfaceEvent.dotBlock);
      _dotArmed = false;
    }
    if (_dot.value) {
      _dotOffSince = null;
    } else {
      _dotOffSince ??= now;
      if (now.difference(_dotOffSince!) >= rearmAfter) _dotArmed = true;
    }

    // 5~8: 선형.
    _linFront.update(front.linear >= presentRatio);
    if (_linFront.value) {
      if (!_onLine) out.add(SurfaceEvent.linearOn);
      _onLine = true;
      _lostSince = null;
    } else if (_onLine) {
      if (f.right.linear >= presentRatio) {
        out.add(SurfaceEvent.linearRight);
        _onLine = false;
        _lostSince = null;
      } else if (f.left.linear >= presentRatio) {
        out.add(SurfaceEvent.linearLeft);
        _onLine = false;
        _lostSince = null;
      } else {
        _lostSince ??= now;
        if (now.difference(_lostSince!) >= lostAfter) {
          out.add(SurfaceEvent.linearLost);
          _onLine = false;
          _lostSince = null;
        }
      }
    }
    return out;
  }
}
