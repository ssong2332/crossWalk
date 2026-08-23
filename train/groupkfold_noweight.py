"""T53 실험: 클래스 불균형 이중 보정을 제거하고 5-class 세션 단위 k-fold를 돌린다.

배경 (2026-08-23):
  5-class 전환 후 동일 표본 106장 기준 right recall이 90.6% -> 70.8%로 떨어졌다.
  퇴행 22건 중 13건은 `approach`가 argmax를 이겼고(일부는 0.95 vs 0.03),
  9건은 right 확률 0.33~0.54로 임계값 0.55에 못 미쳐 무판정이 됐다.

  임계값 조정으로는 복구되지 않음을 저장된 확률로 확인했다:
    - deviation 0.55 -> 0.30: right 70.5% -> 76.8%가 한계 (오경보 6.0% -> 7.6%)
    - approach 임계값 상향: right 70.5% 그대로 (argmax가 이미 approach이므로
      임계값을 올리면 approach가 무판정이 될 뿐 right로 바뀌지 않는다)

가설:
  `groupkfold_cv.run_fold`가 WeightedRandomSampler(1/빈도)와
  CrossEntropyLoss(weight=최다/빈도)를 **둘 다** 걸어 소수 클래스 강조가
  곱으로 누적된다. fold0 train 기준 실효 강조:
    none 1.00 / approach 8.78 / front 2.87 / left 6.69 / right 3.51
  가장 작은 클래스인 approach가 right보다 2.5배 강조되어 argmax를 뺏는다.

방법:
  `groupkfold_cv`를 import해 **설정 전역만 덮어쓴다.** 학습 로직은 원본과
  100% 동일해야 비교가 성립하므로 코드를 복제하지 않는다.
  바뀌는 것은 USE_LOSS_WEIGHT 하나뿐이다 (샘플러는 유지).

착수 전 확정한 판정 기준 (동일 표본 106장 right recall):
  85% 이상  -> 이중 보정이 원인. approach 유지한 채 해결.
  78~85%    -> 부분 해결. 나머지는 데이터 문제.
  78% 미만  -> 가중치 탓 아님. approach 데이터 보강 필요.

비교 대상 (모두 동일 106장):
  (1) 843장 4-class        90.6%
  (2) 638장 5-class        70.8%  <- 현행
  (3) 561장 4-class 대조군 88.7%  (approach 제외, 배포 불가 구성)
"""
from pathlib import Path

import groupkfold_cv as G

# ── 설정 덮어쓰기 (학습 로직은 건드리지 않음) ──────────────────────
G.USE_LOSS_WEIGHT = False
G.OUT_DIR = Path(__file__).resolve().parent / "groupkfold_noweight_out"

assert G.CLASSES == ["none", "approach", "front", "left", "right"], G.CLASSES

if __name__ == "__main__":
    print("[T53 실험] 5-class, 손실가중 제거 (샘플러만)")
    print(f"  CLASSES         = {G.CLASSES}")
    print(f"  USE_LOSS_WEIGHT = {G.USE_LOSS_WEIGHT}")
    print(f"  OUT_DIR         = {G.OUT_DIR}")
    print("  그 외 학습 로직은 groupkfold_cv와 동일 (import해서 설정만 덮어씀)\n", flush=True)
    G.main()
