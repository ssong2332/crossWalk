"""T81: 순수 기하 각도(v3) + 위치 라벨 -> 학습용 최종 각도(위험 가중 포함).

역할 분리 (2026-09-08 사용자 결정):
  - 사람(`label_angles.py`) = **순수 기하 각도만** 매긴다. 사진에 보이는 대로,
    위험하다고 각도를 키우지 않는다.
  - 시스템(이 스크립트) = 위치 라벨(`label_position.py`)을 이용해 위험 가중을
    **투명하고 재현 가능한 공식**으로 얹는다.

  v1/v2는 이 둘이 사람 손에서 섞여 있었다(T74에서 확인: 위치 한 단계당 +7.3도).
  그래서 각도를 사진과 대조해 검증할 수 없었고, 라벨링할 때마다 가중 정도가
  달라져 일관성이 흔들렸다. 분리해 두면 가중 공식만 바꿔 재실험할 수 있다.

공식:
    risk_level = -position   (3_left:  왼쪽 끝(-2)이 최고 위험 -> +2)
    risk_level = +position   (4_right: 오른쪽 끝(+2)이 최고 위험 -> +2)
    최종각도 = 기하각도 + sign(기하각도) * W * max(risk_level, 0)

  - **안전한 쪽(risk_level < 0)은 기하각도를 그대로 둔다**(사용자 확정,
    2026-09-08). v2에서는 안전한 쪽 각도가 중앙보다도 작았지만(T74), 실제로
    이탈한 양을 실제보다 작게 보고할 이유가 없다고 판단했다.
  - front/approach는 건드리지 않는다 — T74에서 위치와 무관함을 확인했다
    (모든 위치에서 평균 ±1도 이내, 표준편차 0.6~0.7).
  - 위치 라벨이 없는 사진은 가중 없이 기하각도를 그대로 쓴다(가중을 0으로
    두는 것이 없는 값을 지어내는 것보다 안전하다). 몇 장이 그런지 보고한다.

W = 3.0도인 근거 (실측):
  v3 기하각도는 이미 크다(3_left 평균 47.8도, 4_right 41.2도, 최대 74.96도).
  화살표 렌더링(`GroundProjection.yawForScreenAngle`)의 탐색 범위가 ±75~80도라
  그 밖으로 나가면 화살표가 범위 끝에서 잘린다. 위치 라벨이 있는 이탈 276장
  기준 W별 최대 |각도|와 75도 초과 장수:
      W=0 -> 73.6도, 0장
      W=2 -> 73.6도, 0장
      W=3 -> 74.3도, 0장   <- 클램프 안에 들어가는 최대값
      W=5 -> 76.3도, 2장
      W=7 -> 78.3도, 3장
  주의: v2에서 사람이 넣던 가중은 26도 기준선 위의 +7.3도(약 28%)였는데,
  v3는 기준선이 44도라 W=3은 약 7%에 그친다. 상대적 강조는 v2보다 약하다.
  더 세게 하려면 `GroundProjection.maxYawDegrees`를 함께 넓혀야 한다.

산출물: train/angle_labels_weighted.csv (학습은 이 파일을 쓴다)
        원본 train/angle_labels.csv 는 건드리지 않는다.
"""
import csv
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ANGLE_CSV = REPO / "train" / "angle_labels.csv"
POS_CSV = REPO / "train" / "position_labels.csv"
OUT_CSV = REPO / "train" / "angle_labels_weighted.csv"

W = 3.0
DEVIATION = {"3_left": -1, "4_right": +1}  # position 부호 -> 위험 방향

# T95(2026-09-16, 사용자 확정): 가장자리(위치 ±2) 규칙.
#   - 이탈(|기하|>=15) & 위험한 쪽 끝(risk_level 2): 단계당 W가 아니라 W_EDGE로
#     더 세게 민다(+12도), 75도 클램프.
#   - 직진(|기하|<15) & 끝: 기하값 대신 **중앙 쪽으로 EDGE_MIN**(오른쪽 끝 -> -20,
#     왼쪽 끝 -> +20). 20도인 이유: T87 이탈 임계 15도를 넘어 상태가 '틀어짐'이
#     되고, T84 '크게' 임계 25도는 넘지 않아 약한 경고로 중앙 유도.
#   - 직진 & 치우침(±1), 안전한 쪽, approach는 그대로.
#   판정은 클래스 폴더가 아니라 **기하 각도 부호**로 한다(AI Hub Surface 사진은
#   클래스가 'on_surface' 하나라 폴더로는 못 나눔; 3_left는 전부 양수, 4_right는
#   전부 음수라 자체 사진에서는 결과가 같다).
W_EDGE = 6.0
EDGE_MIN = 20.0
DEV_T = 15.0
CLAMP = 75.0
EXTRA_ANGLE_CSV = REPO / "train" / "angle_labels_surface.csv"
EXTRA_POS_CSV = REPO / "train" / "position_labels_surface.csv"


def main():
    angles = {}
    for src in (ANGLE_CSV, EXTRA_ANGLE_CSV):
        if not src.exists():
            continue
        for r in csv.DictReader(open(src, encoding="utf-8")):
            if r["status"] == "ok":
                angles[r["filename"]] = r

    positions = {}
    for src in (POS_CSV, EXTRA_POS_CSV):
        if not src.exists():
            continue
        for r in csv.DictReader(open(src, encoding="utf-8")):
            if r["status"] == "ok":
                positions[r["filename"]] = int(r["position"])

    rows = []
    stats = Counter()
    for name, r in angles.items():
        cls = r["class"]
        geo = float(r["angle_deg"])
        pos = positions.get(name)
        risk_level = ""

        if cls == "1_approach":
            final = geo
            stats["가중 대상 아님(approach)"] += 1
        elif pos is None:
            final = geo
            stats["위치 라벨 없음 -> 가중 0"] += 1
        elif abs(geo) < DEV_T:
            # 직진. 끝(±2)이면 중앙 쪽으로 EDGE_MIN (T95).
            if abs(pos) == 2:
                final = (-1 if pos > 0 else 1) * EDGE_MIN
                stats["직진 & 끝 -> 중앙 쪽 ±20도 (T95)"] += 1
            else:
                final = geo
                stats["직진 -> 기하값 유지"] += 1
        else:
            # 이탈. 위험 방향 = 기하 부호로: 양수(왼쪽 이탈)면 왼쪽 끝(-2)이 위험.
            risk_dir = -1 if geo > 0 else +1
            risk_level = risk_dir * pos
            if risk_level >= 2:
                add = W_EDGE * risk_level          # 끝: +12도 (T95)
            else:
                add = W * max(risk_level, 0)       # 치우침: +3도 / 안전한 쪽: 0
            final = geo + (1 if geo >= 0 else -1) * add
            final = max(-CLAMP, min(CLAMP, final))
            stats["이탈 & 끝 -> +12도 (T95)" if risk_level >= 2 else
                  ("가중 적용됨(+3)" if add > 0 else "안전한 쪽 -> 기하값 유지")] += 1

        rows.append({
            "class": cls,
            "filename": name,
            "angle_deg": f"{final:.2f}",
            "geometric_deg": f"{geo:.2f}",
            "position": "" if pos is None else pos,
            "risk_level": risk_level,
            "weight_added": f"{final - geo:+.2f}",
        })

    with open(OUT_CSV, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=[
            "class", "filename", "angle_deg", "geometric_deg",
            "position", "risk_level", "weight_added"])
        w.writeheader()
        w.writerows(rows)

    print(f"W = {W}도/단계, 끝 W_EDGE = {W_EDGE}도/단계, 직진&끝 = 중앙 쪽 {EDGE_MIN}도, 클램프 ±{CLAMP}도")
    print(f"입력: 기하 라벨 {len(angles)}장 / 위치 라벨 {len(positions)}장")
    for k, v in stats.most_common():
        print(f"  {k}: {v}장")

    changed = [r for r in rows if float(r["weight_added"]) != 0]
    if changed:
        mags = [abs(float(r["angle_deg"])) for r in rows]
        print(f"\n가중이 실제로 더해진 사진: {len(changed)}장 "
              f"(평균 {sum(abs(float(r['weight_added'])) for r in changed)/len(changed):.1f}도)")
        print(f"최종 |각도| 최대: {max(mags):.1f}도 "
              f"(75도 초과 {sum(1 for m in mags if m > 75)}장)")
    print(f"\n저장: {OUT_CSV}")


if __name__ == "__main__":
    main()
