/// T87: **방향은 각도 모델이 정한다.** 분류기는 "횡단보도 없음 / 앞 / 위"만
/// 담당하고, "위"(front·left·right 중 하나)일 때 왼쪽·직진·오른쪽은 각도로
/// 판정한다(사용자 확정, 2026-09-13).
///
/// 왜 — 실기기 35장(2026-09-13)에서 직진인데 "오른쪽으로 틀어짐"(#28·#29),
/// 같은 장면에서 좌/우/직진이 요동(#16~18), 이탈인데 직진(#11·#24)이
/// 반복됐다. 누수 없는 5-fold CV(정답 front/left/right 445장,
/// `train/angle_cv_predictions_named.csv` × `groupkfold_5class_out/all_probs.json`):
///
///   | 방향 3분류                | 정확도 | front 재현 | 이탈 방향 |
///   | 분류기(임계 적용)          | 84.5%  |            |           |
///   | 각도만, |a|<10 → front    | 94.2%  | 94%        | 94%       |
///   | 각도만, |a|<15 → front    | 94.4%  | 100%       | 91%       |
///
/// 각도 부호 정확도는 98.3%(T85). T=15를 고른 이유: 배포 모델을 학습 데이터로
/// 돌리면 진짜 front에서 |예측|>=10이 20.5%, >=15는 4.3%라
/// (`train/screenshot_probe_after_v3.log`) 실기기에서 직진을 이탈로 부르는
/// 빈도가 T=10에서는 더 높을 수 있다. 실기기 뒤 조정 가능.
///
/// 이 표가 T85(반대면 뒤집음)·T86(front인데 큰 각도면 "방향 확인 중")을
/// 흡수한다 — 둘 다 "분류기가 방향을 정하고 각도가 교정"하던 구조의
/// 땜질이었고, 이제 방향의 주체가 각도라 필요 없다.
///
/// 판정표(사용자 확정):
///   | 분류기 L            | 각도 a      | 최종                         |
///   | none / approach     | 무엇이든    | L 그대로                     |
///   | front/left/right    | null        | L 그대로 (각도 미준비·미검출) |
///   | front/left/right    | |a| < 15    | front                        |
///   | front/left/right    | a >= +15    | left  (오른쪽으로 가라)       |
///   | front/left/right    | a <= -15    | right (왼쪽으로 가라)         |
///   각도가 갱신될 때마다 마지막 "위" 상태를 새 각도로 **재판정**한다 —
///   분류기가 저신뢰로 결과를 안 내는 동안(classifier.dart:244) 문구가 옛
///   방향에 멈춰 있고 화살표만 돌던 실기기 #14 경로를 막는다.
///
/// 알려진 위험: ±15 경계에서 front <-> 이탈이 오갈 수 있다(히스테리시스
/// 없음 — 판정표에 없어 넣지 않았다). 실기기에서 잦으면 별도 태스크.
///
/// 부호 규약(T71 검증): 각도는 **가야 할 방향**. 왼쪽 이탈(3_left)은
/// 오른쪽으로 가야 하므로 양수, 오른쪽 이탈(4_right)은 음수.
class DirectionResolver {
  DirectionResolver._();

  /// 이 크기 미만이면 직진. 근거는 위 표.
  static const double deviationAngleDegrees = 15.0;

  /// 분류기가 "횡단보도 위"라고 본 상태인가.
  static bool isOnCrosswalk(String label) =>
      label == 'front' || label == 'left' || label == 'right';

  /// 분류기 [label]과 각도 모델의 [angleDegrees]를 합쳐 최종 상태를 낸다.
  static String resolve(String label, double? angleDegrees) {
    if (!isOnCrosswalk(label)) return label;
    if (angleDegrees == null) return label;
    if (angleDegrees >= deviationAngleDegrees) return 'left';
    if (angleDegrees <= -deviationAngleDegrees) return 'right';
    return 'front';
  }
}
