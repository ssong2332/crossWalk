"""재라벨링 2차(2026-08-23) 반영 세션 단위 5-fold 재측정.

변경된 것 — 라벨 18장뿐이다:
  approach -> front  10장
  approach -> right   8장
  (신규·삭제 0장. 총 638장 유지)
이동한 18장은 `train/approach_direction.csv`에 미리 적어둔 방향과
정확히 일치한다(front 10건, right 8건 모두 CSV의 direction과 동일).

클래스별 장수: none 229 / approach 59 / front 140 / left 89 / right 121

학습 설정:
  USE_LOSS_WEIGHT = False  (T53에서 확인한 공짜 이득 — right 70.8->75.2%,
  none 83.0->87.8%, 오경보 증가 없음. 가설 자체는 기각됐지만 개선은 유지한다.)

주의:
  `approach`가 59장으로 최소 클래스가 됐다. T53에서 소수 클래스가 불리하다는
  것을 확인했으므로 approach recall은 더 떨어질 수 있다 — 추정이며 이 실행으로 확인한다.
"""
from pathlib import Path

import groupkfold_cv as G

G.USE_LOSS_WEIGHT = False
G.OUT_DIR = Path(__file__).resolve().parent / "groupkfold_relabel2_out"

assert G.CLASSES == ["none", "approach", "front", "left", "right"], G.CLASSES

if __name__ == "__main__":
    print("[재라벨링 2차] 5-class, 손실가중 OFF")
    print(f"  OUT_DIR = {G.OUT_DIR}\n", flush=True)
    G.main()
