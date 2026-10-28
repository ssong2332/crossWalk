# T150 각도 시범 라벨링 가이드 (50장, 시간 재기)

## 금지
- 위험하다고 각도를 더 꺾지 않는다. 위험 가중은 `apply_risk_weighting.py`가 나중에 따로 한다.
- 애매하면 억지로 긋지 않고 **S(건너뛰기)** 를 누른다. 억지 라벨은 학습을 망친다.
- 라벨 파일(`train/angle_labels_t150_pilot*.csv`)을 손으로 고치지 않는다. 고칠 때는 도구의 **Z** 를 쓴다.

## 실행 (한 줄)
PR이 머지된 뒤, `C:\vibecoding\crossWalk` 에서:
```
python train/t150_label_angles.py
```
- 머지 전에 해 보려면: `python C:\vibecoding\crossWalk\.claude\worktrees\t150-angle-label-pilot-0c0213\train\t150_label_angles.py --root C:/vibecoding/crossWalk`
- 끝나거나 Q로 닫으면 시간 요약이 자동으로 나온다. 요약만 다시 보기: `python train/t150_label_angles.py --summary`

## 키
| 키 | 동작 |
|---|---|
| 마우스 드래그 | 선 긋기 (시작점 → 끝점 방향이 진행 방향) |
| Enter / Space | 저장하고 다음 장 (선이 없으면 저장 안 됨) |
| S | 건너뛰기 (횡단보도가 안 보이거나 방향을 못 정함) |
| Z | 직전 장으로 돌아가기 (그 장의 라벨 줄이 지워짐, 다시 그으면 됨) |
| R | 지금 선 지우고 다시 긋기 |
| Q | 종료. 다시 실행하면 안 한 장부터 이어서 |

## 선 긋는 규칙 (기존 `label_angles.py` 와 같음)
| 항목 | 규칙 |
|---|---|
| 무엇을 긋나 | "지금 이 자리에서 횡단보도를 건너려면 걸어갈 방향" (`label_angles.py:28-41`) |
| 기준 | 사진에 보이는 그대로(카메라 기준). 원근을 머릿속으로 보정하지 않는다 |
| 각도 | 화면 위쪽 = 0°, 시계방향 = +, 반시계방향 = − (왼쪽 위 노란 숫자로 표시) |
| 사진 방향 | 도구가 시계방향 90° 돌려 세로로 보여 준다. 저장 좌표도 이 화면 기준 (T94와 같음) |
| 모델 예측 | 화면에 보여 주지 않는다 (예측에 끌려가지 않게) |
| 비스듬한 횡단보도 | 줄무늬 방향과 걸어갈 방향이 다를 수 있다. **처리 방법은 아직 결정 보류** — 이번 시범에서는 평소대로 긋고, 애매하면 S |

## 시범 50장 구성 (`train/t150_pilot50.csv`)
| 날짜 폴더 | 중간 (예측 12~30°) | 작음 (<12°) | 큼 (≥30°) |
|---|---|---|---|
| frames_1025 · 1025b · 1026 · 1027 · 1028b | 각 8 | 각 1 | 각 1 |
| 합계 | 40 | 5 | 5 |
- 구간은 **모델 예측** 기준이다(정답 아님). 장소 정보는 기록에 없어서, 같은 횡단(프레임 간격 10초 이내 묶음)이 몰리지 않게 묶음을 돌아가며 뽑았다. 서로 3초 이내 사진은 뽑지 않았다.
- 고른 방법: `train/t150_select_pilot.py` (seed 150, 다시 실행해도 같은 50장). 후보 전체 1,397장은 `train/t150_candidates.csv`.

## 저장 파일
| 파일 | 열 | 비고 |
|---|---|---|
| `train/angle_labels_t150_pilot.csv` | `class,filename,angle_deg,x1,y1,x2,y2,view_w,view_h,status` | `angle_labels.csv` 와 같은 열. `class` = 프레임 폴더 이름(예: `frames_1027`), 사진 = `train/<class>/<filename>` |
| `train/angle_labels_t150_pilot_times.csv` | `class,filename,action,sec,at` | 장당 소요 초. `action` = ok / skipped / undo. 되돌린 시간도 남긴다 |

## 끝나면
1. 요약 출력(합계 분, 장당 중앙값, "680장이면 약 N시간")을 오케스트레이터에게 알려 준다.
2. 쉬는 동안 창을 열어 두면 그 장의 시간이 늘어난다. 쉴 때는 Q로 닫고 나중에 다시 실행한다.
