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

/// 모델 클래스 번호(`train/train_seg_t105.py`와 같다 — 0~5는 T104와 같은 번호).
/// T105(2026-10-12): 앱 모델을 9클래스로 바꿨다. 6클래스 모델을 넣어도 동작한다
/// (6~8의 비율이 0으로 나올 뿐).
class SurfaceClass {
  SurfaceClass._();
  static const background = 0;
  static const sidewalk = 1;
  static const road = 2;
  static const crosswalk = 3;
  static const linear = 4;
  static const dot = 5;
  static const stairs = 6;
  static const manholeGrating = 7;
  static const treeZone = 8;
  static const count = 9;
}

enum SurfaceEvent { road, dotBlock, linearOn, linearRight, linearLeft, linearLost }

/// T105: 주의 구역 안내(`docs/CautionGuidance.md`) 이벤트.
enum CautionEvent { manholeGrating, treeZone }

/// 한 칸(영역)의 클래스별 면적 비율(0~1).
class SurfaceRegion {
  const SurfaceRegion(
      {this.sidewalk = 0,
      this.road = 0,
      this.linear = 0,
      this.dot = 0,
      this.stairs = 0,
      this.manholeGrating = 0,
      this.treeZone = 0,
      this.crosswalk = 0});

  final double sidewalk;
  final double road;
  final double linear;
  final double dot;
  final double stairs;
  final double manholeGrating;
  final double treeZone;

  /// T125: 기록용(판정표에는 안 씀).
  final double crosswalk;

  @override
  String toString() => '인도 ${_p(sidewalk)} 차도 ${_p(road)} '
      '선형 ${_p(linear)} 점형 ${_p(dot)} 맨홀 ${_p(manholeGrating)} 가로수 ${_p(treeZone)}';

  static String _p(double v) => (v * 100).toStringAsFixed(0);
}

class SurfaceFeatures {
  const SurfaceFeatures(
      {this.left = const SurfaceRegion(),
      this.front = const SurfaceRegion(),
      this.right = const SurfaceRegion(),
      this.crosswalkAll = 0});

  final SurfaceRegion left;
  final SurfaceRegion front;
  final SurfaceRegion right;

  /// T125: **화면 전체**(위 절반 포함)의 횡단보도 픽셀 비율 — 노면 횡단보도 확인
  /// (`CrosswalkSurfaceGate`)과 기록에 쓴다. 학습 사진 분석(`surface_cw.csv` cw_all)과 같은 정의.
  final double crosswalkAll;

  /// 모델 출력 로짓 `[클래스][세로][가로]`(배치 차원 제거)에서 아래 절반을 argmax해
  /// 세 칸의 비율을 낸다. 크기는 리스트 길이에서 읽는다. T125: 위 절반도 argmax해
  /// 화면 전체 횡단보도 비율([crosswalkAll])만 센다.
  static SurfaceFeatures fromLogits(List logits) {
    final nCls = logits.length;
    final h = (logits[0] as List).length;
    final w = ((logits[0] as List)[0] as List).length;
    final counts = List.generate(3, (_) => List<int>.filled(SurfaceClass.count, 0));
    final totals = List<int>.filled(3, 0);
    var crosswalkPixels = 0;
    for (var y = 0; y < h; y++) {
      final bottom = y >= h ~/ 2;
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
        if (best == SurfaceClass.crosswalk) crosswalkPixels++;
        if (!bottom) continue;
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
        stairs: counts[i][SurfaceClass.stairs] / t,
        manholeGrating: counts[i][SurfaceClass.manholeGrating] / t,
        treeZone: counts[i][SurfaceClass.treeZone] / t,
        crosswalk: counts[i][SurfaceClass.crosswalk] / t,
      );
    }

    return SurfaceFeatures(
        left: r(0),
        front: r(1),
        right: r(2),
        crosswalkAll: h * w == 0 ? 0 : crosswalkPixels / (h * w));
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

/// T105: 주의 구역 안내 판정 — `docs/CautionGuidance.md` 판정표(사용자 확정 2026-10-01)의 구현.
///
///   | #  | 분류기 상태      | 조건 (연속 2회 확인 후)                   | 이벤트          |
///   | C1 | none / crossed   | 앞 맨홀·그레이팅 없음 -> 있음(앞 칸 10% 이상) | manholeGrating ("발밑 주의", P2) |
///   | C2 | none / crossed   | 앞 가로수 구역 없음 -> 있음(10% 이상)      | treeZone ("가로수", P2) |
///   | C3 | none / crossed   | C1·C2가 같은 판정의 노면 이벤트(B)와 겹침  | 없음 — B만 말하고, 그 등장은 다시 말하지 않음 |
///   | C4 | none / crossed   | 계단                                       | 없음 (모델 미달) |
///   | C5~C7 | approach·위·hold·무판정 | 무엇이든                         | 없음(상태 초기화) |
/// 반복: 1회. 3초 이상 없었다가 다시 나타나야 다시 말한다(B 멈춤 블록과 같은 방식).
/// 기준값(10%, 2회, 3초)은 추정이다 — 문서 §6.
class CautionGuide {
  static const presentRatio = 0.10;
  static const rearmAfter = Duration(seconds: 3);

  _Debounced _manhole = _Debounced();
  _Debounced _tree = _Debounced();
  bool _manholeArmed = true;
  bool _treeArmed = true;
  DateTime? _manholeOffSince;
  DateTime? _treeOffSince;

  void reset() {
    _manhole = _Debounced();
    _tree = _Debounced();
    _manholeArmed = true;
    _treeArmed = true;
    _manholeOffSince = null;
    _treeOffSince = null;
  }

  /// 분할 결과 하나를 넣고 이번에 낼 이벤트를 돌려준다.
  /// [surfaceEventFired]는 같은 판정에서 노면 안내(B) 이벤트가 났는지(C3).
  List<CautionEvent> update(SurfaceFeatures f, String state, DateTime now,
      {bool surfaceEventFired = false}) {
    if (!SurfaceGuide.isActiveState(state)) {
      reset();
      return const [];
    }
    final out = <CautionEvent>[];

    final manholeRose =
        _manhole.update(f.front.manholeGrating >= presentRatio) && _manhole.value;
    if (manholeRose && _manholeArmed) {
      // C3: B와 겹치면 말하지 않지만, 이 등장은 쓴 것으로 친다.
      if (!surfaceEventFired) out.add(CautionEvent.manholeGrating);
      _manholeArmed = false;
    }
    if (_manhole.value) {
      _manholeOffSince = null;
    } else {
      _manholeOffSince ??= now;
      if (now.difference(_manholeOffSince!) >= rearmAfter) _manholeArmed = true;
    }

    final treeRose = _tree.update(f.front.treeZone >= presentRatio) && _tree.value;
    if (treeRose && _treeArmed) {
      if (!surfaceEventFired) out.add(CautionEvent.treeZone);
      _treeArmed = false;
    }
    if (_tree.value) {
      _treeOffSince = null;
    } else {
      _treeOffSince ??= now;
      if (now.difference(_treeOffSince!) >= rearmAfter) _treeArmed = true;
    }
    return out;
  }
}
