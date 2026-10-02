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

## 3. 사건 표

| `ev` | 언제 | 주요 키 | 어디서 |
|---|---|---|---|
| `log.start` | 기록 파일을 연 직후 | `file`, `build`(CI 커밋 SHA) | `event_log.dart` `start` |
| `log.on` / `log.off` | 설정에서 기록을 켬/끔 | — | `event_log.dart` `setEnabled` |
| `log.share` | 기록 보내기 | `files`(개수), `status`(공유 창 결과) 또는 `err` | `camera_screen.dart` `_shareEventLog` |
| `app.life` | 앱 생명주기 변화 | `state`(resumed/inactive/hidden/paused/detached) | `camera_screen.dart` `didChangeAppLifecycleState` |
| `set` | 설정 변경 | `key`(lang/speechRate/vibrationMs/surface/torch/powerSave), `value` | `feedback_service.dart`, `camera_screen.dart` |
| `model` | 모델 불러오기 | `name`(cls/angle/pos/surface), `ok`, `ms` 또는 `err` | `camera_screen.dart` `_initCamera`, `_setSurfaceEnabled` |
| `camera` | 카메라 스트림 시작 | `ok`, `sensor`(센서 회전), `preview`(크기) | `camera_screen.dart` `_initCamera` |
| `error` | 초기화 실패 | `where`(permission/camera/model_integrity/init), `msg` 또는 `permanent` | `camera_screen.dart` `_initCamera` |
| `cls` | 분류기가 실제로 돈 프레임 (처리 프레임 5개 중 1번) | `best`(최고 클래스), `conf`(스무딩 평균 확률), `ok`(임계값 통과), `probs`(이번 프레임 6클래스), `avg`(스무딩 평균 6클래스), `dur`(ms) | `camera_screen.dart` `_onFrame` |
| `angle` | 각도 모델이 돈 프레임 | `raw`, `smooth`, `label`, `dur` | `_updateAngleEstimate` |
| `pos` | 위치 모델이 돈 프레임 | `raw`, `smooth`, `label`, `dur` | `_updatePositionEstimate` |
| `surf` | 노면 모델이 돈 프레임 (노면 안내가 켜졌을 때만) | `L`/`F`/`R` = **[인도, 차도, 선형, 점형] 비율**, `st`(화면 상태), `dur`, `ok` | `_updateSurfaceGuidance` |
| `surf.ev` | 노면 판정표 이벤트 | `ev`(road/dotBlock/linearOn/linearRight/linearLeft/linearLost 목록), `st` | `_updateSurfaceGuidance` |
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
