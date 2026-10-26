/// T138: 연석 '위' 오판 막기(노면 횡단보도 확인 설정 켬일 때만) — 아직 건너지 않았는데
/// 분류기가 위(front/left/right)를 내도, 발밑(화면 맨 아래 1/6 줄)에 횡단보도가
/// 적고 인도·점자블록이 보이면 approach로 낮춘다. 이어서 기존 노면 확인
/// (`CrosswalkSurfaceGate`)이 그 approach를 평가한다.
///
/// 배경(2026-10-26 밤 실기기, `log_20261026_213316.jsonl`): 연석에서 신호를 기다리는데
/// 위로 잡힌 곳 2곳(15.3초·4.7초)과 인도 위 짧은 오판 2곳(1.9초·0.9초), 그 때문에
/// 잘못 나간 '횡단보도 진입.' 2건(L1021, L6094). 연석 #1은 아래 절반 앞 칸이 횡단보도
/// 0.5~0.9라 기존 노면 값으로는 못 막고, 맨 아래 줄에서만 횡단보도가 적다
/// (프레임 오프라인 재현, `docs/Tasks.md` T138).
///
/// 판정표(오케스트레이터 승인 2026-10-27, 순수 Dart — 시간은 인자로 주입):
///   | # | 조건                                                    | 결과      | 기록 |
///   | 1 | 설정 꺼짐                                               | 그대로    | 없음 |
///   | 2 | 분류 라벨이 front/left/right가 아님                      | 그대로    | 없음 |
///   | 3 | 직전 최종 상태가 front/left/right/hold(이미 건너는 중)    | 그대로    | 없음 |
///   | 4 | 최근 노면 판정 [window]개가 [maxAge] 안에 있고 모두 발밑 횡단보도 < [maxCrosswalk] 그리고 인도+블록 >= [minGround] | approach | `cwgate` act=front_drop |
///   | 5 | 그 밖                                                   | 그대로    | 없음 |
/// 3행 때문에 hold(T103)·발밑 인도 조기 해제(T118)와 겹치지 않는다 — 진입 순간에만
/// 동작한다. 4행의 인도+블록 조건은 가려진·검은 화면(배경만 보임)에서 내리지 않으려는
/// 보수안이다. 기준값(0.5, 0.1, 2개, 2.5초, 1/6)은 추정이다.
library;

import 'crossing_hold.dart';
import 'direction_resolver.dart';
import 'surface_guide.dart';

/// 발밑(분할 결과 맨 아래 1/6 줄, 전체 폭)의 비율.
class FootSurface {
  const FootSurface({this.ground = 0, this.crosswalk = 0});

  /// 인도+선형+점형 비율.
  final double ground;

  /// 횡단보도 비율.
  final double crosswalk;

  /// 화면 높이 중 발밑으로 보는 몫의 분모(맨 아래 1/6).
  static const bandDivisor = 6;

  /// 모델 출력 로짓 `[클래스][세로][가로]`(배치 차원 제거)의 맨 아래 1/6 줄을
  /// argmax해 비율을 낸다(224줄이면 187~223줄). 크기는 리스트 길이에서 읽는다.
  static FootSurface fromLogits(List logits) {
    final nCls = logits.length;
    final h = (logits[0] as List).length;
    final w = ((logits[0] as List)[0] as List).length;
    final y0 = h - h ~/ bandDivisor;
    var ground = 0;
    var crosswalk = 0;
    var total = 0;
    for (var y = y0; y < h; y++) {
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
        if (best == SurfaceClass.crosswalk) crosswalk++;
        if (best == SurfaceClass.sidewalk ||
            best == SurfaceClass.linear ||
            best == SurfaceClass.dot) {
          ground++;
        }
        total++;
      }
    }
    if (total == 0) return const FootSurface();
    return FootSurface(ground: ground / total, crosswalk: crosswalk / total);
  }
}

class CurbFrontResult {
  const CurbFrontResult(this.label, {this.dropped = false, this.samples = const []});

  /// 이어서 노면 확인·방향 판정으로 보낼 라벨.
  final String label;

  /// 4행으로 approach로 낮췄는가.
  final bool dropped;

  /// 4행에서 쓴 발밑 값(오래된 것부터). 그 밖에는 비어 있다.
  final List<FootSurface> samples;
}

class CurbFrontGate {
  /// 발밑 횡단보도 비율 상한 — 10/26 연석 #1 맨 아래 1/6 줄 0.06~0.41, 실제 횡단 중
  /// 대부분 0.6 이상(오프라인 재현).
  static const maxCrosswalk = 0.5;

  /// 발밑 인도+블록 하한 — 이보다 적으면 배경·검은 화면으로 보고 내리지 않는다.
  static const minGround = 0.1;

  /// 연속 확인 수. 노면 판정은 약 0.4~0.5초마다 돈다.
  static const window = 2;

  /// 노면 모델을 막 켰거나 멈췄을 때 오래된 판정을 쓰지 않는다(노면 확인과 같은 2.5초).
  static const maxAge = Duration(milliseconds: 2500);

  final List<(DateTime, FootSurface)> _samples = [];

  /// 노면 모델이 돈 프레임마다 발밑 값을 넣는다.
  void note(FootSurface foot, DateTime now) {
    _samples.add((now, foot));
    if (_samples.length > window) _samples.removeAt(0);
  }

  void reset() => _samples.clear();

  /// 분류 라벨 [label]과 직전 최종 상태 [current]로 판정표를 적용한다.
  CurbFrontResult apply(String label,
      {required String current, required bool enabled, required DateTime now}) {
    if (!enabled) return CurbFrontResult(label);
    if (!DirectionResolver.isOnCrosswalk(label)) return CurbFrontResult(label);
    if (DirectionResolver.isOnCrosswalk(current) ||
        current == CrossingHold.holdLabel) {
      return CurbFrontResult(label);
    }
    final recent = [
      for (final (t, f) in _samples)
        if (now.difference(t) <= maxAge) f
    ];
    if (recent.length < window) return CurbFrontResult(label);
    final curb = recent.every(
        (f) => f.crosswalk < maxCrosswalk && f.ground >= minGround);
    if (!curb) return CurbFrontResult(label);
    return CurbFrontResult('approach', dropped: true, samples: recent);
  }
}
