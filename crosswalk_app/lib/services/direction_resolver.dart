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
/// T103(2026-09-27, 사용자 확정): 기준 **15 -> 12**, 경계 떨림 방지 추가.
///   사용자가 2_front 중 |라벨| >= 5도 44장을 재검토해 25장을 좌/우 이탈로
///   바꿨다(`train/review_t102/front_review_log.csv`) — 15도는 작은 이탈을
///   놓친다는 판단. T100 각도 CV(`angle_cv_pred_t100_952.csv`, front 275장):
///     | 기준 | 직진->이탈 오경보 | left 감지 | right 감지 |
///     | 15   | 5.1%              | 91.0%     | 91.9%      |
///     | 12   | 6.5%              | 94.3%     | 94.7%      |
///   (오경보 칸에는 T100에서 front로 옮긴 작은 이탈이 섞여 실제보다 불리하다.)
///   떨림 방지: 이탈로 **들어갈 때는 12도**, 이미 같은 방향 이탈이면 **9도
///   이상인 동안 유지**하고 그 밑에서 직진으로 돌아온다. 9는 선택지 예시로
///   제안한 값이다(실기기 뒤 조정).
///   판정표(T87 표의 15를 대체, 끝 규칙 뒤에 본다):
///     | 직전 상태 | 각도 a          | 최종  |
///     | left      | a >= +9         | left  |
///     | right     | a <= -9         | right |
///     | 그 외     | a >= +12        | left  |
///     | 그 외     | a <= -12        | right |
///     | 그 외     | |a| < 12        | front |
///
/// 부호 규약(T71 검증): 각도는 **가야 할 방향**. 왼쪽 이탈(3_left)은
/// 오른쪽으로 가야 하므로 양수, 오른쪽 이탈(4_right)은 음수.
///
/// T98(2026-09-19, 사용자 최종 목표): **끝이면 각도와 무관하게 중앙 쪽으로.**
///   왼쪽 끝이면 직진·이탈이든 오른쪽으로, 오른쪽 끝이면 왼쪽으로 보내
///   사용자가 폭 안(치우침~중앙)에서 건너게 한다. 위치는 별도 회귀 모델
///   (`PositionEstimator`, -2 왼쪽 끝 ~ +2 오른쪽 끝)이 내고, 여기서 규칙으로
///   각도 판정에 **앞서** 적용한다.
///
///   근거(누수 없는 5-fold CV, 횡단보도 위 사진만, `train/position_cv_t98b.log`):
///   임계 1.0에서 오검출은 거의 전부 "치우침(±1)"이고 반대쪽 끝·중앙을
///   끝으로 부른 경우는 0~소수, **반대 방향으로 보낸 경우 0장**. 치우친
///   사용자를 중앙 쪽으로 보내는 건 무해하므로 임계 1.0을 쓴다(사용자 승인 C안).
///
/// 판정표(T98 + T100, 사용자 확정) — 각도 표보다 먼저 본다:
///   | 분류기 L         | 위치 p      | 각도 a            | 최종                                  |
///   | none / approach  | 무엇이든    | 무엇이든          | L 그대로 (위치 규칙 미적용)           |
///   | front/left/right | null        | —                 | 아래 각도 표로                         |
///   | front/left/right | p <= -1.0   | a > -15 또는 null | left  (오른쪽으로 가라, 각도 +20 취급) |
///   | front/left/right | p <= -1.0   | a <= -15          | front (이미 오른쪽으로 틀었음, 각도 0) |
///   | front/left/right | p >= +1.0   | a < +15 또는 null | right (왼쪽으로 가라, 각도 -20 취급)   |
///   | front/left/right | p >= +1.0   | a >= +15          | front (이미 왼쪽으로 틀었음, 각도 0)   |
///   | front/left/right | -1 < p < 1  | —                 | 아래 각도 표로                         |
///
///   T100(2026-09-21, 실기기 #1·#3): 끝에서 "오른쪽으로"를 듣고 오른쪽으로 틀어도
///   위치는 아직 끝이라 "오른쪽으로"가 계속 유지됐다. 각도 모델은 이때 반대
///   부호(줄무늬에 다시 나란해지려면 왼쪽)를 내므로, **끝 + 각도가 중앙 쪽으로
///   ±15 이상이면 "이미 틀었다"로 보고 직진(유지)** 을 낸다(사용자 선택 a안).
///   화살표·강도 각도는 0으로 두어 "직진"과 모순되지 않게 한다.
///
///   T137(2026-10-27, 사용자 승인 결정 1-a): "이미 틀었음"에 **상한 25°**.
///   10/26 밤 실기기(`train/field_1026/report.md` ⑥(a), 21:41:41~52·21:48:45):
///   왼쪽 끝에서 32~42° 틀어진 채 서 있어도 '그대로 가세요'가 12장 나왔다.
///   중앙 쪽으로 튼 각도가 [edgeTurnedMaxDegrees]를 넘으면 끝 규칙을 적용하지
///   않고(null) 아래 각도 표의 이탈 판정을 그대로 쓴다(지나치게 틀어 반대쪽 이탈).
///     | 위치 p    | 각도 a                 | 최종                         |
///     | p <= -1.0 | -25 <= a <= -12        | front (이미 틀었음)          |
///     | p <= -1.0 | a < -25                | 각도 표 → right (왼쪽으로)   |
///     | p >= +1.0 | +12 <= a <= +25        | front (이미 틀었음)          |
///     | p >= +1.0 | a > +25                | 각도 표 → left (오른쪽으로)  |
///
///   T143(2026-10-27, 사용자 승인 "추천대로 진행하자"): "이미 틀었음"의 상한·하한에
///   **떨림 방지**. 10/27 낮 실기기(`train/field_1027/report.md` 2장): 12:27:32~44에
///   각도가 25° 근처를 오가며 '즉시 왼쪽으로'와 '그대로 가세요'가 번갈아 나왔다
///   (25 경계 뒤집힘 기록 전체 9회 중 6회가 이 12초). 하한도 12:28:19.5→20.9에
///   1.4초 만에 끝 유도 ↔ 이미 틀었음 왕복이 있었다(`train/t143_edge_turned_replay.py`).
///   들어가는 기준은 그대로 두고, 이미 그 상태면 더 넓게 유지한다(T103과 같은 방식):
///     | 직전 상태                        | 중앙 쪽 각도 m      | 최종                  |
///     | 이미 틀었음(front + 끝)           | 9 <= m <= 25        | 이미 틀었음 유지      |
///     | 이미 틀었음                       | m > 25              | 각도 표(이탈)         |
///     | 이미 틀었음                       | m < 9               | 끝 유도(중앙 쪽으로)  |
///     | 상한 넘어 이탈(왼쪽 끝 right,     | m > 21              | 각도 표(이탈) 유지    |
///     |   오른쪽 끝 left)                 | 12 <= m <= 21       | 이미 틀었음           |
///     | 그 외(끝 유도·일반 직진 등)       | 12 <= m <= 25       | 이미 틀었음           |
///   [previousAtEdge]가 직전 상태가 끝 규칙에서 나왔는지를 알린다(front + 끝 =
///   이미 틀었음). 21은 사용자 승인 값, 9는 T103 유지 기준과 같은 값(실기기 뒤 조정).
///
/// T146(2026-10-28, 사용자 승인 A~C, 오케스트레이터 확정 (a)안): **단계를 각도로 정한다.**
///   10/28 실기기(`train/field_1028/report_angle.md` §1·§3): 단계 2가 위치(끝)에 묶여
///   있어 큰 이탈 뒤 몸을 직진 쪽으로 돌려도 2→1→0으로 내려간 경우가 34번 중 0번,
///   끝↔반대 방향 뒤집힘 31번(한 구간 19번, 앞 25초는 서 있음).
///   - 보정각 c = 각도 + 끝 보정. 끝이면 가야 할 방향이 중앙 쪽으로
///     [edgeSteerDegrees](20°) 옮겨진다: 왼쪽 끝 c = a + 20, 오른쪽 끝 c = a − 20,
///     끝이 아니면 c = a. 각도가 없으면 끝에서 ±20, 아니면 없음.
///     → 위 T98/T100/T137/T143 끝 표(±20 고정, '이미 틀었음' 12~25, 상한 25/21,
///     하한 12/9)를 **대체**한다. '이미 틀었음'은 끝에서 |c| < 12인 상태(중앙 쪽
///     8~32°)이고, 반대 방향 안내는 중앙 쪽으로 32° 넘게 돌았을 때만 나온다(종전 25°).
///   - 방향 판정은 c에 T103 표(진입 12 / 유지 9)를 그대로 건다.
///   - 단계([deviationLevel])도 |c|로: 0 = 12~20, 1 = 20~30, 2 = 30 이상.
///     올라갈 때는 기준값, 내려갈 때는 [levelHysteresisDegrees](3°) 아래(17 / 27).
///   - 끝 판정([edgeSide])에 떨림 방지: 들어갈 때 |p| >= 1.0, 나올 때 |p| < 0.8.
///   - 끝이라는 사실은 단계가 아니라 음성·화면 문구로만 알린다([isEdge]).
///   - T146 ②(사용자 승인 2026-10-28 "추천대로 같이 넣어서 진행하자"): 끝 보정을 위치에
///     따라 점점 키운다 — |p| [edgeRampStartPosition](0.5)→[edgePosition](1.0)에서
///     중앙 쪽 0→20° 선형([edgeShiftDegrees]), 끝 판정과 무관하게. 계단(끝이면 20, 아니면 0)이면
///     '이미 틀었음'(중앙 쪽 15°)인 채 위치가 0.8 밑으로 내려오는 순간 목표가 20°→0°로 바뀌어
///     같은 각도가 반대 방향 안내가 됐다(10/28 재생 끝 경계 뒤집힘 18). 재생 비교
///     (`train/t146_report.md`): 계단 28/18/12, 0.8→1.0(끝 판정 안만) 33/13/15,
///     **0.5→1.0 25/12/18** (전체 뒤집힘/끝 경계 뒤집힘/2→1→0).
///   경계 상수는 모두 이 클래스에 모아 둔다(실기기 체감 뒤 조정).
class DirectionResolver {
  DirectionResolver._();

  /// 이 크기 이상이면 이탈로 **들어간다**. 근거는 위 표(T103: 15 -> 12).
  /// T146: 끝에서는 보정각 c에 건다.
  static const double deviationAngleDegrees = 12.0;

  /// T103: 이미 같은 방향 이탈이면 이 크기 이상인 동안 이탈을 **유지**한다
  /// (경계 떨림 방지). 이 밑으로 내려가야 직진으로 돌아온다.
  static const double recoverAngleDegrees = 9.0;

  /// T98: |위치| 가 이 값 이상이면 "끝"으로 **들어간다**(라벨 단위: ±2가 끝).
  static const double edgePosition = 1.0;

  /// T146 B: 이미 끝이면 |위치|가 이 값 이상인 동안 끝을 **유지**한다.
  /// 10/28 서 있을 때 위치 평균 −1.04, sd 0.24, 44%가 1.0 위(보고서 §3).
  static const double edgeExitPosition = 0.8;

  /// T98: 끝일 때 가야 할 방향을 중앙 쪽으로 옮기는 크기(도).
  /// T146: 보정각 c = 각도 + 끝 보정, |p| >= 1.0이면 끝 보정 = ±이 값.
  static const double edgeSteerDegrees = 20.0;

  /// T146 ②: 끝 보정이 0에서 커지기 시작하는 |위치|. 여기서 [edgePosition]까지
  /// 0→[edgeSteerDegrees] 선형.
  static const double edgeRampStartPosition = 0.5;

  /// T146 A: 단계 1(중간)·2(큰 이탈)로 **올라가는** |c| 기준(오케스트레이터 확정 (a)안).
  /// 12/30은 T144 CV 표(`report_angle.md` §4-4)에서 중간 단계가 가장 나은 경계.
  static const double level1Degrees = 20.0;
  static const double level2Degrees = 30.0;

  /// T146 A: 단계가 **내려갈 때** 기준보다 이만큼 아래로 와야 내려간다(20→17, 30→27).
  /// 끝에서 직진하면 c = 20이라 단계 0/1 경계에 정확히 걸린다 — 떨림 방지가 없으면
  /// 서 있을 때 박자가 계속 바뀐다. 3°는 오케스트레이터 제안 값(`train/t146_report.md`).
  static const double levelHysteresisDegrees = 3.0;

  /// T146 C: 서 있을 때 각도·위치 EMA 계수(걸을 때 0.6, `camera_screen.dart`).
  /// 0.3이면 응답이 약 2배 느려지고 떨림이 줄어든다(T70-3 표 기준 추정).
  static const double stillSmoothingFactor = 0.3;

  /// T146 C: 서 있을 때 반대 방향 안내로 바꾸려면 반대 판정이 이만큼 이어져야 한다
  /// ([StillOppositeDelay]).
  static const stillOppositeHold = Duration(milliseconds: 1500);

  /// T146 B: 끝 판정. −1 = 왼쪽 끝, +1 = 오른쪽 끝, 0 = 끝 아님.
  /// [previousSide]가 같은 쪽 끝이면 |p| >= [edgeExitPosition]인 동안 유지한다.
  static int edgeSide(double? position, {int previousSide = 0}) {
    if (position == null) return 0;
    if (position <= -edgePosition) return -1;
    if (position >= edgePosition) return 1;
    if (previousSide == -1 && position <= -edgeExitPosition) return -1;
    if (previousSide == 1 && position >= edgeExitPosition) return 1;
    return 0;
  }

  /// T146 ②: 끝 보정(도, +면 오른쪽으로). 중앙 쪽으로 |p| 0.5→1.0에서 0→20 선형,
  /// 1.0 이상 20. 왼쪽(p < 0)이면 +, 오른쪽이면 −. 위치가 없으면 [edgeSide]로 ±20/0.
  static double edgeShiftDegrees(double? position, int edgeSide) {
    if (position == null) return -edgeSide * edgeSteerDegrees;
    final f = ((position.abs() - edgeRampStartPosition) /
            (edgePosition - edgeRampStartPosition))
        .clamp(0.0, 1.0);
    return (position < 0 ? 1.0 : -1.0) * edgeSteerDegrees * f;
  }

  /// T146 A: 보정각 c(가야 할 방향과 지금 방향의 차이, +면 오른쪽으로).
  ///   c = 각도 + [edgeShiftDegrees]. 왼쪽 끝(|p| >= 1) a + 20, 오른쪽 끝 a − 20,
  ///   |p| <= 0.5면 a. 각도가 없으면 끝 판정일 때만 끝 보정, 아니면 없음.
  static double? correctedAngle(double? angleDegrees, int edgeSide,
      {double? position}) {
    final shift = edgeShiftDegrees(position, edgeSide);
    if (angleDegrees == null) return edgeSide == 0 ? null : shift;
    return angleDegrees + shift;
  }

  /// T143: 끝에서 중앙 쪽으로 보내는 상태(왼쪽 끝 → left "오른쪽으로",
  /// 오른쪽 끝 → right "왼쪽으로"). 끝이 아니면 null. "이미 틀었음"의 진동 방향에 쓴다.
  static String? edgeSteerClass(int edgeSide) =>
      edgeSide < 0 ? 'left' : (edgeSide > 0 ? 'right' : null);

  /// T102/T146: 최종 상태 [resolvedLabel]에 끝 문구를 쓰는가.
  ///   끝 + 중앙 쪽 이탈 → 끝 안내("…가세요. 가장자리입니다"),
  ///   끝 + front → 이미 중앙 쪽으로 틀었음("그대로 가세요").
  ///   끝 + 반대 방향(지나치게 돎) → 일반 이탈 안내(끝 아님).
  ///   none/approach면 옛 위치값이 남아 있어도 false.
  static bool isEdge(String resolvedLabel, int edgeSide) =>
      edgeSide != 0 &&
      (resolvedLabel == 'front' || resolvedLabel == edgeSteerClass(edgeSide));

  /// 분류기가 "횡단보도 위"라고 본 상태인가.
  static bool isOnCrosswalk(String label) =>
      label == 'front' || label == 'left' || label == 'right';

  /// 분류기 [label]과 각도 모델의 [angleDegrees], 끝 판정 [edgeSide]·위치 [position]을
  /// 합쳐 최종 상태를 낸다. T146: 보정각 c에 T103 표를 건다.
  /// [previous]는 직전 최종 상태 — 떨림 방지(T103)에 쓴다.
  static String resolve(String label, double? angleDegrees,
      {int edgeSide = 0, double? position, String? previous}) {
    if (!isOnCrosswalk(label)) return label;
    final c = correctedAngle(angleDegrees, edgeSide, position: position);
    if (c == null) return label;
    if (previous == 'left' && c >= recoverAngleDegrees) return 'left';
    if (previous == 'right' && c <= -recoverAngleDegrees) return 'right';
    if (c >= deviationAngleDegrees) return 'left';
    if (c <= -deviationAngleDegrees) return 'right';
    return 'front';
  }

  /// T146 A: 이탈 단계 — |c|로 정한다. 0 = 보통(12~20), 1 = 중간(20~30), 2 = 큰(30~).
  ///   [previous]는 같은 방향 직전 단계(방향이 바뀌었거나 처음이면 null).
  ///   올라갈 때는 즉시, 내려갈 때는 기준 − [levelHysteresisDegrees] 밑으로 와야 한다.
  ///   각도가 없으면 0.
  static int deviationLevel(double? correctedAngleDegrees, {int? previous}) {
    if (correctedAngleDegrees == null) return 0;
    final m = correctedAngleDegrees.abs();
    final up = m >= level2Degrees ? 2 : (m >= level1Degrees ? 1 : 0);
    if (previous == null || previous <= up) return up;
    if (previous >= 2 && m >= level2Degrees - levelHysteresisDegrees) return 2;
    if (m >= level1Degrees - levelHysteresisDegrees) return 1;
    return 0;
  }
}

/// T146 C(사용자 승인 2026-10-28): 서 있을 때 반대 방향 안내로 바로 바꾸지 않는다.
///
/// 10/28 16:52:31~16:53:44(`train/field_1028/report_angle.md` §3): 서 있는 동안에도
/// 폰이 ±20° 흔들려 '오른쪽으로…가장자리' ↔ '즉시 왼쪽으로'가 번갈아 나왔다.
///
/// 판정표 ([DirectionResolver.resolve] 결과 뒤에 본다, 시간은 인자로 주입):
///   | # | 조건                                                         | 결과            |
///   | 1 | 결과가 위(front/left/right)가 아님                           | 그대로, 기억 지움 |
///   | 2 | 결과 front                                                   | 그대로 (후보 지움) |
///   | 3 | 결과 left/right, 마지막 이탈 방향 없음 또는 같은 방향          | 그대로, 방향 기억 |
///   | 4 | 반대 방향 + 서 있지 않음                                     | 그대로, 방향 기억 |
///   | 5 | 반대 방향 + 서 있음 + 반대 판정이 [hold] 미만 이어짐           | **직전 상태 유지** (held) |
///   | 6 | 반대 방향 + 서 있음 + [hold] 이상 이어짐                      | 바꿈, 방향 기억 |
/// '마지막 이탈 방향' = 마지막으로 내보낸 left/right(사이에 front가 있어도 기억).
/// '이어짐' = 반대 판정이 끊기지 않고(front·같은 방향이 끼면 처음부터) 계속된 시간.
/// 막았을 때 내보내는 '직전 상태'가 위가 아니거나 반대 방향 그 자체면 front.
class StillOppositeDelay {
  StillOppositeDelay({this.hold = DirectionResolver.stillOppositeHold});

  final Duration hold;

  String? _lastDir;
  String? _candidate;
  DateTime? _since;

  /// [resolved]를 받아 내보낼 상태를 돌려준다.
  ({String label, bool held}) apply(String resolved,
      {required String previous, required bool still, required DateTime now}) {
    if (!DirectionResolver.isOnCrosswalk(resolved)) {
      reset();
      return (label: resolved, held: false);
    }
    if (resolved == 'front') {
      _candidate = null;
      _since = null;
      return (label: resolved, held: false);
    }
    final last = _lastDir;
    if (last == null || last == resolved || !still) {
      _lastDir = resolved;
      _candidate = null;
      _since = null;
      return (label: resolved, held: false);
    }
    if (_candidate != resolved) {
      _candidate = resolved;
      _since = now;
    }
    if (now.difference(_since!) >= hold) {
      _lastDir = resolved;
      _candidate = null;
      _since = null;
      return (label: resolved, held: false);
    }
    final keep =
        DirectionResolver.isOnCrosswalk(previous) && previous != resolved
            ? previous
            : 'front';
    return (label: keep, held: true);
  }

  void reset() {
    _lastDir = null;
    _candidate = null;
    _since = null;
  }
}

/// T130 [EdgeAngleFlipGuard.apply]의 결과.
class FlipGuardDecision {
  const FlipGuardDecision(this.label,
      {this.held = false, this.from, this.source, this.sinceMs});

  /// 최종 상태. 막았으면 직전 상태 그대로.
  final String label;

  /// 끝↔각도 뒤집힘을 막았는가. 막았으면 끝 안내·끝 각도를 쓰지 않는다.
  final bool held;

  /// 막았을 때: 직전 경고 방향, 막은 판정의 출처(`edge`/`angle`), 직전 방향에
  /// 마지막으로 있던 때부터 지난 시간(ms).
  final String? from;
  final String? source;
  final int? sinceMs;
}

/// T130 (사용자 승인 2026-10-25): 위치 '끝' 판정과 각도 판정이 반대 방향일 때
/// 1초 안에 반대쪽으로 뒤집지 않는다.
///
/// 야간 실기기(`logs/log_20261024_191344.jsonl`, `train/field_1024n/report.md`
/// 추가 확인): 3초 안 좌우 뒤집힘 25회 중 15회가 끝 규칙과 각도 규칙이 번갈아
/// 이긴 경우(19:28:22~36 14초에 9번 왕복). 예: 오른쪽 끝(위치 >= 1) → "왼쪽으로
/// 가세요. 가장자리입니다", 다음 위치가 1 밑 + 각도 +20 → "오른쪽으로 가세요".
///
/// 판정표 ([DirectionResolver.resolve] 결과 뒤에 본다, 시간은 인자로 주입):
///   | # | 조건                                                          | 결과        |
///   | 1 | 결과가 위(front/left/right)가 아님                            | 그대로, 기억 지움 |
///   | 2 | 결과 front                                                    | 그대로      |
///   | 3 | 결과 left/right, 기억한 방향 없음(첫 경고) 또는 같은 방향       | 그대로      |
///   | 4 | 직전 상태가 위가 아님                                         | 그대로      |
///   | 5 | 반대 방향 + 출처(끝/각도)가 다름 + 직전 방향에 마지막으로 있던  | **직전 상태 유지** (held) |
///   |   | 때부터 [window] 안                                            |             |
///   | 6 | 그 밖(반대 방향이지만 같은 출처, 또는 [window] 지남)           | 그대로      |
/// 출처: 위치가 끝([DirectionResolver.edgePosition] 이상)이면 `edge`, 아니면 `angle`
/// (T146: 끝 규칙이 보정각으로 바뀌어 위치만 본다 — 꺼져 있는 동안 동작 차이 없음).
/// '마지막으로 있던 때' = 그 방향 상태였던 마지막 판정 시각(직진으로 바뀐 순간 포함).
/// 막은 판정은 기억을 갱신하지 않는다 — 막는 것이 [window]를 넘겨 이어지지 않게.
/// 1초는 사용자 결정 값이다(실기기 뒤 조정).
///
/// T132 ③(사용자 승인 2026-10-25): **꺼 둔다**([enabledByDefault] = false). 10/25
/// 주간·저녁 두 시험에서 틀린 경고를 막았다고 확인된 묶음 0, 맞는 경고를 0.2~0.9초
/// 늦춘 묶음 6(`train/field_1025b/fliphold.json`). 꺼져 있으면 [apply]는 받은
/// 판정을 그대로 돌려주고 막지 않는다(`flip.hold` 기록도 없음). 코드는 지우지 않고
/// 상수로 끈다 — 다시 켜 볼 때 이 상수만 바꾸면 되고, 판정표 테스트도 남는다.
class EdgeAngleFlipGuard {
  EdgeAngleFlipGuard({this.enabled = enabledByDefault});

  static const window = Duration(seconds: 1);

  /// T132 ③: 앱이 쓰는 기본값. false면 막지 않는다.
  static const enabledByDefault = false;

  /// false면 [apply]가 아무것도 막지 않는다.
  final bool enabled;

  String? _dir;
  String? _source;
  DateTime? _lastInDir;

  FlipGuardDecision apply(String resolved,
      {required String previous,
      double? position,
      double? angleDegrees,
      required DateTime now}) {
    if (!enabled) return FlipGuardDecision(resolved);
    if (!DirectionResolver.isOnCrosswalk(resolved)) {
      reset();
      return FlipGuardDecision(resolved);
    }
    if (resolved == 'front') {
      if (previous == _dir) _lastInDir = now;
      return FlipGuardDecision(resolved);
    }
    final source = DirectionResolver.edgeSide(position) != 0 ? 'edge' : 'angle';
    final dir = _dir;
    final lastIn = _lastInDir;
    if (dir != null &&
        lastIn != null &&
        resolved != dir &&
        source != _source &&
        DirectionResolver.isOnCrosswalk(previous) &&
        now.difference(lastIn) < window) {
      return FlipGuardDecision(previous,
          held: true,
          from: dir,
          source: source,
          sinceMs: now.difference(lastIn).inMilliseconds);
    }
    _dir = resolved;
    _source = source;
    _lastInDir = now;
    return FlipGuardDecision(resolved);
  }

  void reset() {
    _dir = null;
    _source = null;
    _lastInDir = null;
  }
}
