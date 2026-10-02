# 개발용 기록 (T106)

**상태:** 사용자 확정 (2026-10-02, Q1~Q5 제안안). 코드는 `crosswalk_app/lib/services/event_log.dart`(기록기)와 각 기록 지점(아래 §3 "어디서")에 있다. 태스크: `docs/Tasks.md` T106.

## 금지 (다른 모든 규칙보다 우선)
- **카메라 영상·사진, 위치(GPS), 개인 정보는 기록하지 않는다** (Q1, Q4). 프레임을 저장하려면 따로 결정한다.
- **앱에 인터넷 권한을 더하지 않는다.** 기록은 폰 안에만 있고, 사용자가 "기록 보내기"로 직접 고른 앱으로만 나간다 (Q2).
- 기록 때문에 판정·음성·진동이 늦어지거나 깨지면 안 된다. `EventLog.log()`는 동기이고 예외를 밖으로 내지 않으며, 파일 쓰기는 2초마다 모아서 한다.
- 기록은 판정 근거가 아니다. 판정 코드는 기록 값을 읽지 않는다(`AudioPolicy.lastReason`, `Classifier.last*`는 기록 전용).
- 이 표에 없는 사건을 기록에 더할 때는 이 문서의 §3 표에 행을 먼저 추가한다.

## 1. 결정 기록 (사용자 확정 2026-10-02)

| # | 질문 | 확정 |
|---|---|---|
| Q1 | 기록 항목 | §3 표 |
| Q2 | 폰 → PC | 설정 › 개발용 기록 › **기록 보내기** → 안드로이드 공유 창 (`share_plus`) |
| Q3 | 기본값 | **켬**. 설정에서 끌 수 있음. 출시 전에 다시 결정 |
| Q4 | 카메라 프레임 저장 | 이번에는 안 함 |
| Q5 | 순서 | 기록 빌드를 먼저 만들고, 그 빌드로 B(노면 안내) 실기기 테스트 |

## 2. 파일

| 항목 | 값 |
|---|---|
| 위치 | 앱 전용 폴더 `getApplicationSupportDirectory()/logs/` (다른 앱은 못 읽음) |
| 이름 | `log_YYYYMMDD_HHMMSS.jsonl` — 앱을 켤 때마다 1개, 이름순 = 시간순 |
| 형식 | JSON Lines: 한 줄에 사건 하나 |
| 쓰기 | 2초마다 모아서 붙임. 64KB가 쌓이면 바로. 화면에서 내려갈 때(`app.life`가 resumed 아님) 즉시 |
| 크기 상한 | 합계 50MB. 앱을 켤 때 넘으면 오래된 파일부터 지움 |
| 예상 크기 | 시간당 약 2MB (추정: 초당 약 5줄 × 약 150바이트, 실측 필요) |
| 실수 | 소수 4자리로 반올림. NaN·무한대는 `null` |

공통 키 (모든 줄):

| 키 | 뜻 |
|---|---|
| `t` | 폰 시계, epoch 밀리초. 화면 녹화(파일 이름의 시작 시각 + 영상 안 시각)와 맞출 때 쓴다 |
| `ms` | 앱 프로세스 시작 뒤 경과 밀리초. 폰 시계가 바뀌어도 순서가 맞다 |
| `ev` | 사건 이름 (§3) |

`t`·`ms`·`ev`는 데이터 키로 쓰지 않는다. 실수로 쓰면 기록기가 `_t`·`_ms`·`_ev`로 옮겨 적는다(`EventLog.reservedKeys`).

## 3. 사건 표

| `ev` | 언제 | 주요 키 | 어디서 |
|---|---|---|---|
| `log.start` | 기록 파일을 연 직후 | `file`, `build`(CI 커밋 SHA) | `event_log.dart` `start` |
| `log.on` / `log.off` | 설정에서 기록을 켬/끔 | — | `event_log.dart` `setEnabled` |
| `log.share` | 기록 보내기 | `files`(개수), `status`(공유 창 결과) 또는 `err` | `camera_screen.dart` `_shareEventLog` |
| `app.life` | 앱 생명주기 변화 | `state`(resumed/inactive/hidden/paused/detached) | `camera_screen.dart` `didChangeAppLifecycleState` |
| `set` | 설정 변경 | `key`(lang/speechRate/vibrationMs/surface/torch/powerSave), `value` | `feedback_service.dart`, `camera_screen.dart` |
| `model` | 모델 불러오기 | `name`(cls/angle/pos/surface), `ok`, `dur`(ms) 또는 `err` | `camera_screen.dart` `_initCamera`, `_setSurfaceEnabled` |
| `camera` | 카메라 스트림 시작 | `ok`, `sensor`(센서 회전), `preview`(크기) | `camera_screen.dart` `_initCamera` |
| `error` | 초기화 실패 | `where`(permission/camera/model_integrity/init), `msg` 또는 `permanent` | `camera_screen.dart` `_initCamera` |
| `cls` | 분류기가 실제로 돈 프레임 (처리 프레임 5개 중 1번) | `best`(최고 클래스), `conf`(스무딩 평균 확률), `ok`(임계값 통과), `probs`(이번 프레임 6클래스), `avg`(스무딩 평균 6클래스), `dur`(ms) | `camera_screen.dart` `_onFrame` |
| `angle` | 각도 모델이 돈 프레임 | `raw`, `smooth`, `label`, `dur` | `_updateAngleEstimate` |
| `pos` | 위치 모델이 돈 프레임 | `raw`, `smooth`, `label`, `dur` | `_updatePositionEstimate` |
| `surf` | 노면 모델이 돈 프레임 (노면 안내가 켜졌을 때만) | `L`/`F`/`R` = **[인도, 차도, 선형, 점형] 비율**, `st`(화면 상태), `dur`, `ok` | `_updateSurfaceGuidance` |
| `surf.ev` | 노면 판정표 이벤트 | `names`(road/dotBlock/linearOn/linearRight/linearLeft/linearLost 목록), `st` | `_updateSurfaceGuidance` |
| `state` | 화면 상태가 바뀜 (무판정·오류 포함, 1초 안) | `from`, `to`, `edge`, `conf` | `_logStateIfChanged` |
| `alert` | 이탈 안내 판단 한 번 | `cls`, `conf`, `ang`, `edge`, `msg`/`phase`/`recover`/`edgeTurned`(이번에 고른 문장, 없으면 null), `vib`(진동 여부) | `feedback_service.dart` `alert` |
| `say` | 음성 요청 | `text`, `p`(0~3 = P0~P3), `act`(speakNow/queue/drop), `why`(§4) | `feedback_service.dart` `_speak` |
| `say.end` | 음성 재생이 끝남 | `text`, `p`, `res`(done/timeout/error), `dur`(ms) — 다른 안내가 끊으면 짧게 끝난다 | `_speak` |
| `say.ttl` | 대기하던 안내가 TTL을 넘겨 버려짐 | `text`, `p` | `_drainPending` |
| `vib` | 진동 요청 | `kind`(left/right/recover/road/line_on), `ok`, `mode`(pattern/single), `pat`(ms 배열: 대기·켬·끔…) 또는 `why`(no_vibrator) | `feedback_service.dart` `alert`, `surfaceAlert` |

`vib`는 앱이 진동을 **요청한** 기록이다. 모터가 실제로 떨렸는지, 사용자가 느꼈는지는 체크리스트로만 안다.

## 4. `say.why` (AudioPolicy 판단 이유)

| 값 | 뜻 | 결과 |
|---|---|---|
| `p0` | 재생 중인 것이 없고 P0 | 즉시 |
| `ok` | 간격·예산 안 | 즉시 |
| `interrupt_pN` | 재생 중인 pN 이하 등급을 끊음 | 즉시 |
| `wait_p0` | P0 재생 중에 P1 | 대기 |
| `busy_pN` | 더 높은 등급 pN 재생 중 | 버림 |
| `min_gap` | 직전 안내 끝난 뒤 1.5초 안 | 버림 |
| `budget` | 60초에 20초 예산 초과 | 버림 |

## 5. 쓰는 법

1. 설정 › 개발용 기록 › **기록 보내기** → 구글 드라이브·카톡 나와의 채팅·Quick Share 등 → PC.
2. PC에서 한 폴더에 모은다 (예: `logs/`).
3. 읽기 예:

```python
import json
rows = [json.loads(l) for l in open("log_20261002_071530.jsonl", encoding="utf-8")]
vib = [r for r in rows if r["ev"] == "vib"]
```

## 6. 한계

- 시간당 크기·쓰기 부담은 추정이다. 첫 실기기 기록에서 `cls.dur`·`surf.dur`이 기록 전 측정값(분류기 83~88ms, 노면 96~99ms)과 같은지 확인한다.
- 앱이 강제 종료되면 마지막 2초 안의 기록은 잃을 수 있다.
- 설정은 앱을 다시 켜면 기본값으로 돌아간다(이 앱의 다른 설정과 같음). 기록은 기본 켬이라 다시 켜진다.

## 7. 분석 (`train/field_log_t106.py`) — 접근성 경험(AX) 중심

사용자 결정(2026-10-02): 분석은 **시각장애 사용자가 실제로 겪는 것**을 시계열로 본다.

실행:

```
python train/field_log_t106.py logs/log_*.jsonl --out train/field_t106/<이름> --video videos/<녹화>.mp4 --checklist <체크리스트>.json
python train/field_log_t106.py --selftest
```

- 체크리스트 JSON은 Claude가 체크리스트 Artifact의 db(`results`/`meta`/`notes`)를 읽어 만든다.
- 출력:
  - `summary.json`: 지표와 근거(파일:줄)
  - `report.md`
  - `timeline_*.png`: 전체
  - `window_*_dev*.png`: 이탈 구간 확대
  - `window_*_scene*.png`: 장면 확대
  - `frames_*.jpg`: 사건 순간의 영상 프레임

### 7.1 지표 판정 기준 (초안 — 실제 기록에 적용하기 전 사용자 확인)

| 지표 | 판정 (if → then) | 기준값 (추정) |
|---|---|---|
| 이탈 경고 첫 반응 | 상태가 left/right로 바뀐 시각 → 첫 이탈 음성 시작 또는 진동 요청까지 | 측정값 (같은 프레임 안 순서 때문에 0.5초 먼저 나온 안내도 포함) |
| 각도 근거 → 이탈 | 이탈 시작 전 5초 안에 각도가 12° 이상으로 올라간 마지막 시각 → 이탈 상태까지 | 12° (T103) |
| 이탈 중 침묵 | 이탈 상태인데 이탈 음성·진동 사이 간격이 기준보다 길다 | 4.0초 (재알림 3초 + 분류기 주기 0.5초 + 여유 0.5초) |
| 깜빡임 | 상태가 바뀐 뒤 기준 시간 안에 바로 전 상태로 돌아옴 | 1.0초 |
| 끊긴 안내 | 음성 X가 끝난 시각(±0.05초)에 다른 음성 요청이 있음 | 0.05초 |
| 못 들은 안내 | `say.act=drop` 또는 `say.ttl` | — |
| 반복 안내 | 같은 문장이 기준 시간 안에 다시 재생 | 10초 |
| 소리 점유 | 60초 창 안 음성 재생 합계 (P0 포함, 사용자가 들은 전체) | 20초 (AudioPolicy 예산과 같은 값) |
| 판정 없음 | 상태 nocall·error·loading의 합계와 최장 구간 | — |
| 처리 공백 | 분류기 결과 간격이 기준보다 김 (앱이 내려간 구간 제외) | 1.0초 |
| 노면 변화 반응 | 앞 칸 차도 ≥ 50% / 점형·선형 ≥ 5%로 처음 넘은 시각 → 3초 안의 해당 노면 이벤트 | 50% · 5% · 3초 |

### 7.2 장면 판정표 (초안 — 사용자 확인 전)

체크리스트의 녹화 시각 −5초 ~ +10초 창에서 앱이 낸 것을 보고, 사용자 체감(됨/안 됨)과 교차한다.

| 장면 | 앱이 해야 할 일 |
|---|---|
| A 선형 블록에 올라서기 | 진동 `line_on`, 노면 음성 없음 |
| B 왼쪽으로 비켜서기 | `linearRight` + "점자블록 오른쪽" |
| C 오른쪽으로 비켜서기 | `linearLeft` + "점자블록 왼쪽" |
| D 블록에서 멀리 벗어나기 | `linearLost` + "점자블록을 벗어났습니다" |
| E 멈춤(점형) 블록 | `dotBlock` + "멈춤 블록입니다", `dotBlock` 1회 이하 |
| F 인도에서 차도 비추기 | `road` + "차도입니다" + 진동 `road` |
| G 횡단보도 건너기 | 상태가 횡단보도 위(front/left/right/hold)인 동안 노면 음성 0 |
| H 스위치 끄고 확인 | 노면 안내 끄기 기록 뒤 노면 이벤트 0 |

| 앱 | 사용자 | 판정 |
|---|---|---|
| 냄 | 됨 | 정상 |
| 냄 | 안 됨 | 앱은 냈는데 사용자가 못 받음 — 인지 문제(소리·진동 세기, 타이밍, 소음) |
| 안 냄 | 됨 | 체감은 됐는데 기록에 없음 — 창 위치·녹화 시각 확인 필요 |
| 안 냄 | 안 됨 | 앱이 안 냄 — 감지·판정 문제 |

### 7.3 영상 맞추기

- 녹화 파일 이름의 시작 시각(폰 시계, 초 단위)을 기준으로 삼는다.
- 기록의 음성 시작 시각과 영상 소리의 시작 시각을 맞춰 오프셋을 찾는다(±8초 범위, 0.3초 허용).
  - 3개 이상 맞으면 그 오프셋을 쓴다.
  - 아니면 파일 이름 시각만 쓴다(1초 안팎 오차 가능, 추정).
- 화면 녹화의 소리 설정이 "미디어 소리"여야 소리로 맞출 수 있다.
- 프레임은 요청 시각까지 차례로 읽어서 뽑는다. 9/29 녹화 실측 오차는 최대 0.038초다(키프레임 탐색만 하면 0.61초).
