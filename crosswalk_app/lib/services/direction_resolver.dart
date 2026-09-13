/// T85: 분류기 상태와 각도 모델이 서로 반대 방향을 말할 때 **각도 모델을
/// 따른다** (사용자 선택 B안, 2026-09-13).
///
/// 배경 — T79는 반대 상황이었다:
///   T79(2026-09-07)는 두 모델이 모순이면 각도를 버리고 분류기 방향의
///   평면 화살표로 되돌아갔다. 근거는 당시 v2 각도 모델(604장)을 **학습
///   데이터**로 평가해 "모순 41장 중 29장(70.7%)은 분류기가 맞다"였는데,
///   그 41장은 부호 반대(15)와 |각도|<5(38)를 합친 것이라 "반대 방향"만
///   따로 본 수치가 아니었다.
///
/// T85 실측 (v3 각도 모델, **누수 없는 5-fold CV**, 분류기가 left/right로
/// 판정한 정답 left/right 251장, `train/angle_cv_predictions_named.csv` ×
/// `groupkfold_5class_out/all_probs.json`):
///   - 불일치 8장(3.2%)
///   - 각도가 **반대 방향**(|각도|>=5): 5장 → 각도 5 / 분류기 0 정답
///   - 각도가 **중립**(|각도|<5): 3장 → 분류기 2 정답, 둘 다 틀림 1
///   - 각도 CV 부호 정확도 98.3% (분류기 방향 정확도 ~78%보다 높다)
///   n이 작다(5장). 배포 모델을 학습 데이터로 돌린 보조 수치는
///   `train/t85_disagreement_probe.log` 참고.
///
/// 규칙(판정표, 사용자 확정):
///   | 상태       | 각도            | 결과                         |
///   | left/right | 같은 방향, >=5  | 그대로                       |
///   | left/right | 반대 방향, >=5  | **각도 방향으로 뒤집음**     |
///   | left/right | 중립 |각도|<5   | 분류기 방향 유지             |
///   | left/right | 각도 없음       | 그대로                       |
///   | 그 외      | 무엇이든        | 그대로 (front는 T86에서 다룸) |
///
/// 뒤집힌 상태는 문구·색·화살표·음성·진동 **전부**에 적용된다 — 한 화면에서
/// 문구는 오른쪽, 화살표는 왼쪽을 가리키는 일이 없게 하려는 것이다.
///
/// 부호 규약(T71 검증): 각도는 **가야 할 방향**이다. 왼쪽 이탈(3_left)은
/// 오른쪽으로 가야 하므로 양수, 오른쪽 이탈(4_right)은 음수.
class DirectionResolver {
  DirectionResolver._();

  /// 이 크기 미만이면 각도가 방향을 말하지 않는 것으로 본다(중립).
  /// 5도인 근거는 T79와 같다: v2 라벨의 front 범위가 ±2.6도, 이탈 시작이
  /// ±5.0도 — 5도 미만은 라벨 기준으로도 직진 구간이다.
  static const double neutralAngleDegrees = 5.0;

  /// T86: 분류기가 front(직진)라는데 각도가 이 크기 이상이면 "방향 확인 중"
  /// 으로 표시한다(문구·색만 바뀌고 상태·음성·진동은 front 그대로).
  ///
  /// 왜: 실기기 #13 — front 75%인데 각도 -16도로 화살표는 왼쪽을 가리켰다.
  /// T79는 front에 크기 제약을 두지 않아 안전망이 없었다. 누수 없는 CV에서
  /// 정답 left/right 317장 중 front로 오판이 10장(3.2%)이고 front 확신이
  /// 0.80~0.92인 것도 있어 임계값으로는 못 거른다 — 각도가 유일한 단서다.
  ///
  /// 15도인 근거: 진짜 front 185장에서 배포 모델 |예측|>=15도는 8장(4.3%),
  /// 라벨 기준 0장(`train/screenshot_probe_after_v3.log`). 즉 오경보 4.3%.
  /// 사용자 확정(2026-09-13). 음성은 실기기 확인 뒤 결정하기로 했다.
  static const double frontUncertainAngleDegrees = 15.0;

  /// [label]이 front인데 각도 크기가 [frontUncertainAngleDegrees] 이상인가.
  static bool frontLooksDeviated(String label, double? angleDegrees) =>
      label == 'front' &&
      angleDegrees != null &&
      angleDegrees.abs() >= frontUncertainAngleDegrees;

  /// 분류기 [label]과 각도 모델의 [angleDegrees]를 합쳐 최종 방향을 낸다.
  static String resolve(String label, double? angleDegrees) {
    if (label != 'left' && label != 'right') return label;
    if (angleDegrees == null) return label;
    if (angleDegrees >= neutralAngleDegrees) return 'left';
    if (angleDegrees <= -neutralAngleDegrees) return 'right';
    return label;
  }
}
