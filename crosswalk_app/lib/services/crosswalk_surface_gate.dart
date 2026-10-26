/// T125: 노면 횡단보도 확인(개발 설정, 기본 꺼짐) — 분류기가 approach라고 해도
/// 노면 모델이 최근에 횡단보도를 거의 못 봤으면 none으로 낮춘다.
///
/// 배경(2026-10-21 실기기, `log_20261021_171500-4.jsonl`): 줄무늬 없는 연석·멈춤
/// 블록에서 approach 오인 6구간(approach 확률 0.87~1.00). 학습 사진에서 노면 모델의
/// 횡단보도 비율(화면 전체) 1% 이상인 비율은 approach 80% / front 88% / none 5%,
/// 줄무늬 없는 연석 none 6장은 모두 0% (`train/false_approach_1021/surface_cw.csv`).
///
/// 판정표(`docs/SurfaceGuidance.md` §T125, 순수 Dart — 시간은 인자로 주입):
///   | #  | 조건                                           | 결과 라벨 | 기록 `v` |
///   | 1  | 설정 꺼짐                                      | 그대로    | (안 남김) |
///   | 2  | 분류 라벨이 approach가 아님                    | 그대로    | (안 남김) |
///   | 2b | 초광각 0.6배 켬 또는 가로 장착 (T126)          | approach  | `skip`   |
///   | 3  | 최근 노면 판정 없음(노면 모델 안 돎·오래됨)      | approach  | `na`     |
///   | 4  | 최근 노면 판정의 횡단보도 비율 최대값 >= 1%      | approach  | `keep`   |
///   | 5  | 최근 노면 판정의 횡단보도 비율 최대값 < 1%       | none      | `drop`   |
/// "최근" = 마지막 [window]개 중 [maxAge] 안의 것. 기준값(1%, 5개, 2.5초)은 추정이다.
///
/// T126(2b행): 노면 모델은 세로·1배 사진으로만 학습했다. 10/24 실기기 13:37:26
/// 가로(landscapeTopRight)+0.6배에서 진짜 횡단보도 줄무늬를 차도로 봐(cw 0, 영상
/// `Screen_Recording_20261024_133741.mp4`, 6초 뒤 실제 진입) 규칙이 켜져 있었다면
/// 진짜 approach를 내렸을 것이다. 그래서 학습 조건 밖에서는 쉰다(`why` = 이유).
library;

class CrosswalkGateResult {
  const CrosswalkGateResult(this.label,
      {this.verdict, this.maxRatio, this.samples = 0, this.why});

  /// 피드백으로 보낼 라벨.
  final String label;

  /// 판정표 2b·3~5행이면 `skip`/`na`/`keep`/`drop`, 평가하지 않았으면(1·2행) null.
  final String? verdict;

  /// `skip`일 때 쉰 이유 — `wide`(0.6배) / `landscape`(가로) / `wide,landscape`.
  final String? why;

  /// 창 안 횡단보도 비율의 최대값(창이 비었으면 null).
  final double? maxRatio;

  /// 창 안 노면 판정 수.
  final int samples;
}

class CrosswalkSurfaceGate {
  /// 화면 전체 횡단보도 비율 기준 — 학습 사진 분석(위 근거)의 1%.
  static const minRatio = 0.01;

  /// 노면 판정은 약 0.41초마다 돈다(10/21 기록 `surf` 간격 중앙값 412ms) —
  /// 5개 ≈ 2초. 진짜 approach 구간(같은 기록, front로 이어진 10구간)은 0.9~5.5초라
  /// 이보다 길게 잡으면 직전 횡단보도의 흔적이 남고, 짧게 잡으면 한 장 실패에 흔들린다.
  static const window = 5;

  /// 노면 모델을 막 켰거나 멈췄을 때 오래된 판정을 쓰지 않는다(5개 × 0.41초 + 여유).
  static const maxAge = Duration(milliseconds: 2500);

  final List<(DateTime, double)> _samples = [];

  /// 노면 모델이 돈 프레임마다 화면 전체 횡단보도 비율을 넣는다.
  void note(double crosswalkRatio, DateTime now) {
    _samples.add((now, crosswalkRatio));
    if (_samples.length > window) _samples.removeAt(0);
  }

  void reset() => _samples.clear();

  /// 2b행(T126): 노면 모델 학습 조건 밖이라 쉬어야 하면 그 이유
  /// (`wide` / `landscape` / `wide,landscape`), 아니면 null. T138 연석 확인도 쓴다.
  static String? skipReason({required bool ultraWide, required bool landscape}) {
    if (!ultraWide && !landscape) return null;
    return [if (ultraWide) 'wide', if (landscape) 'landscape'].join(',');
  }

  CrosswalkGateResult apply(String label,
      {required bool enabled,
      required DateTime now,
      bool ultraWide = false,
      bool landscape = false}) {
    if (!enabled || label != 'approach') return CrosswalkGateResult(label);
    final why = skipReason(ultraWide: ultraWide, landscape: landscape);
    if (why != null) {
      return CrosswalkGateResult(label, verdict: 'skip', why: why);
    }
    final recent = [
      for (final (t, r) in _samples)
        if (now.difference(t) <= maxAge) r
    ];
    if (recent.isEmpty) {
      return CrosswalkGateResult(label, verdict: 'na');
    }
    final maxRatio = recent.reduce((a, b) => a > b ? a : b);
    if (maxRatio >= minRatio) {
      return CrosswalkGateResult(label,
          verdict: 'keep', maxRatio: maxRatio, samples: recent.length);
    }
    return CrosswalkGateResult('none',
        verdict: 'drop', maxRatio: maxRatio, samples: recent.length);
  }
}
