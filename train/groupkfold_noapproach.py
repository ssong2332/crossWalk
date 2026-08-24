"""대조 실험: `approach` 클래스를 빼고 4-class로 세션 단위 k-fold를 돌린다.

목적 (2026-08-23):
  5-class 전환 후 right recall이 동일 표본 106장 기준 90.6% -> 70.8%로 떨어졌다.
  퇴행 22건 중 20건이 `approach`로 오판되거나(10건) 무판정으로 밀렸다(10건).
  두 가설을 가른다:
    가. `approach` 데이터 부족(77장) — 경계를 배우기엔 표본이 적다
    나. `approach`가 개념적으로 right와 분리 불가 — 인도에서 본 우측 횡단보도와
        실제 우측 이탈이 기하학적으로 유사하다
  `approach`를 학습·평가에서 제외했을 때 right가 90%대로 복귀하면 "나"가 유력하고,
  복귀하지 않으면 원인이 다른 데 있다(전체 데이터 감소 등).

방법:
  `groupkfold_cv`를 import해 **설정 전역만 덮어쓴다.** 학습 로직(transform, 모델,
  샘플러, 클래스가중치, 에폭/LR/스케줄러, 세션 분할, 누수 assert)은 원본과
  100% 동일해야 비교가 성립하므로 코드를 복제하지 않는다.

주의:
  이 실험은 `image/1_approach/`의 77장을 **아예 없는 것으로 취급**한다.
  실사용에서 인도 프레임은 반드시 발생하므로, 이 구성을 그대로 배포하면 안 된다.
  어디까지나 원인 규명용 대조군이다.
"""
from pathlib import Path

import groupkfold_cv as G

# ── 설정 덮어쓰기 (학습 로직은 건드리지 않음) ──────────────────────
G.CLASS_DIRS = ["0_none", "2_front", "3_left", "4_right"]
G.CLASSES = ["none", "front", "left", "right"]
G.THRESHOLDS = {"front": G.FRONT_T, "none": G.NONE_T}
G.OUT_DIR = Path(__file__).resolve().parent / "groupkfold_noapproach_out"

assert len(G.CLASS_DIRS) == len(G.CLASSES) == 4
# 폴더명 알파벳 순서 == CLASSES 순서여야 한다 (ImageFolder 규칙과 동일한 전제)
assert G.CLASS_DIRS == sorted(G.CLASS_DIRS), "CLASS_DIRS가 알파벳순이 아님"

if __name__ == "__main__":
    print("[대조 실험] approach 제외 4-class")
    print(f"  CLASS_DIRS = {G.CLASS_DIRS}")
    print(f"  CLASSES    = {G.CLASSES}")
    print(f"  OUT_DIR    = {G.OUT_DIR}")
    print("  학습 로직은 groupkfold_cv와 동일 (import해서 설정만 덮어씀)\n", flush=True)
    G.main()
