# 개발용 기록 (T106)

**상태:** 사용자 확정 (2026-10-02, Q1~Q5 제안안). 코드는 `crosswalk_app/lib/services/event_log.dart`(기록기)와 각 기록 지점(아래 §3 "어디서")에 있다. 태스크: `docs/Tasks.md` T106.

## 금지 (다른 모든 규칙보다 우선)
- **카메라 영상·사진, 위치(GPS), 개인 정보는 기록하지 않는다** (Q1, Q4). 예외 하나: 개발 설정 **프레임 저장**(기본 꺼짐, 사용자 결정 2026-10-21 — §8). 그 밖의 프레임 저장은 따로 결정한다.
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
| Q4 | 카메라 프레임 저장 | 이번에는 안 함 → **2026-10-21 사용자 결정: 개발 설정 '프레임 저장'(기본 꺼짐) 한정 허용** (B안 ①, §8) |
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
| `set` | 설정 변경 | `key`(lang/speechRate/vibrationMs/surface/caution/cwGate/torch/powerSave/ultraWide/mount/frameSave), `value`. `mount`면 `rot`(각도·위치·노면 입력 회전)·`crot`(분류기 입력 회전)도 | `feedback_service.dart`, `camera_screen.dart` |
| `model` | 모델 불러오기 | `name`(cls/angle/pos/surface), `ok`, `dur`(ms) 또는 `err` | `camera_screen.dart` `_initCamera`, `_setSurfaceEnabled` |
| `camera` | 카메라 스트림 시작 | `ok`, `sensor`(센서 회전), `pw`·`ph`(미리보기 폭·높이 숫자 — 2026-10-21 전 기록은 `preview` 문자열이고 릴리스에서 "Instance of 'Size'"로 찍혀 쓸 수 없음), `zoomMin`·`zoomMax`, `cams` | `camera_screen.dart` `_initCamera` |
| `camera.frame` | 카메라를 연 뒤 첫 프레임 (B안 ①) | `iw`·`ih`(이미지 스트림 실제 폭·높이, 센서 방향), `fmt` | `camera_screen.dart` `_onFrame` |
| `zoomSet` | 초광각 설정을 켬·끔, 또는 켠 채로 카메라를 다시 엶 (B안 ①) | `req`(요청 줌), `ok`, `zoomMin`, `why`(unsupported = 최소 줌 ≥ 1·못 읽음) 또는 `err`(예외·플러그인 에러 스트림 내용). `ok`는 "요청이 거절되지 않음"까지만 뜻한다 — 렌즈가 실제로 바뀌었는지는 저장 프레임으로 판정 | `camera_screen.dart` `_applyUltraWide` |
| `frame.start` | 프레임 저장을 켬 | `dir`(묶음 폴더 이름), `mb`(기존 프레임 합계) 또는 `err` | `_setFrameSaveEnabled` |
| `frame` | 프레임 한 장 저장 끝남 | `file`(`f_<t>.jpg`), `ok`, `kb`, `dur`(인코딩+쓰기 ms), `del`(상한 때문에 지운 장 수), `rot`·`crot`, `err` | `_onFrame` |
| `frame.share` | 프레임 보내기 | `files`, `status` 또는 `err` | `_shareFrames` |
| `error` | 초기화 실패 | `where`(permission/camera/model_integrity/init), `msg` 또는 `permanent` | `camera_screen.dart` `_initCamera` |
| `cls` | 분류기가 실제로 돈 프레임 (처리 프레임 5개 중 1번) | `best`(최고 클래스), `conf`(스무딩 평균 확률), `ok`(임계값 통과), `probs`(이번 프레임 6클래스), `avg`(스무딩 평균 6클래스), `dur`(ms) | `camera_screen.dart` `_onFrame` |
| `angle` | 각도 모델이 돈 프레임 | `raw`, `smooth`, `label`, `dur` | `_updateAngleEstimate` |
| `pos` | 위치 모델이 돈 프레임 | `raw`, `smooth`, `label`, `dur` | `_updatePositionEstimate` |
| `surf` | 노면 모델이 돈 프레임 (노면 안내나 주의 구역 안내가 켜졌을 때만) | `L`/`F`/`R` = **[인도, 차도, 선형, 점형, 맨홀·그레이팅, 가로수 구역, 계단, 횡단보도] 비율** (T105가 5~7번째, T125가 8번째를 붙임 — 앞 순서는 그대로), `cw`(T125: **화면 전체** 횡단보도 비율), `foot`(T138: 발밑 = 맨 아래 1/6 줄 전체 폭의 [인도+선형+점형, 횡단보도] 비율), `st`(화면 상태), `dur`, `ok` | `_updateSurfaceGuidance` |
| `cwgate` | 노면 횡단보도 확인(T125, 설정 켬)이 approach 판정을 평가함 — 분류기가 approach를 낸 프레임마다(T138 연석 확인이 낮춘 approach 포함). T138: 같은 설정에서 아직 건너지 않았는데 위가 나와 발밑 조건으로 approach로 낮추면 `act`=front_drop 줄을 먼저 남김(`from` 분류 라벨, `prev` 직전 상태, `fg`/`fc` 쓴 노면 판정 2개의 발밑 인도+블록/횡단보도 비율) — 이 줄에는 `v`가 없음. 0.6배·가로 장착이라 연석 확인을 쉬면 `act`=front_skip(`why` wide / landscape / wide,landscape, `from`, `prev`) | `v`(keep = 유지 / drop = none으로 낮춤 / na = 적용 불가: 최근 노면 판정 없음 / skip = T126: 0.6배·가로라 쉼), `why`(skip일 때만: wide / landscape / wide,landscape), `cw`(최근 노면 판정 횡단보도 비율 최대값, na면 null), `n`(쓴 노면 판정 수), `surf`(노면 모델이 도는 중인지) | `CameraScreen` 분류 결과 처리 |
| `caut.ev` | 주의 구역 판정표 이벤트 (T105) | `names`(manholeGrating/treeZone 목록), `st` | `_updateSurfaceGuidance` |
| `hold.end` | "횡단 중" 유지를 발밑이 인도라서 일찍 풂 (T118 — 10초 만료·위·crossed로 풀린 것은 `state`만 남음) | `why`(ground), `to`(이번 판정), `said`(T140: 위 지속 >= 6초라 "횡단보도를 건넜습니다"를 요청했는가 — 실제 재생 여부는 뒤따르는 `say` 줄), `dur`(T140: 위로 들어온 뒤 해제까지 초, 소수 3자리. 들어온 시각을 모르면 null) | `CameraScreen` 분류 결과 처리 |
| `surf.ev` | 노면 판정표 이벤트 | `names`(road/dotBlock/linearOn/linearRight/linearLeft/linearLost 목록), `st` | `_updateSurfaceGuidance` |
| `surf.mute` | T137: 노면 이벤트 중 말하지 않고 기록만 남긴 것 — '점자블록 왼쪽/오른쪽/벗어났습니다'(`SurfaceGuide.linearSideSpeechEnabled` = false, 10/26 밤 판정 가능 8건 중 1건만 맞음). 같은 판정의 `surf.ev` 바로 뒤에 나온다 | `names`(linearRight/linearLeft/linearLost 목록) | `FeedbackService.surfaceAlert` |
| `state` | 화면 상태가 바뀜 (무판정·오류 포함, 1초 안) | `from`, `to`, `edge`, `conf` | `_logStateIfChanged` |
| `still` | T133: 가속도로 본 '서 있음'이 바뀜 (`StillnessDetector`) / 가속도 센서 오류 | `on`(true = 서 있음), `mot`(바뀐 순간의 움직임 크기 = 최근 1초 \|a\| 표준편차, m/s²) / 오류면 `on`=false, `why`=error | `FeedbackService.addAccelerometer`, `CameraScreen._startStillness` |
| `mot` | T137: 흔들림 값 1초마다 — 기록 남기기가 켜져 있을 때만, 창(최근 1초 표본 5개 이상)이 찬 뒤부터 | `mot`(최근 1초 \|a\| 표준편차, m/s², 소수 3자리 — `still`의 `mot`과 같은 값), `still`(지금 서 있음 판정, 센서 멈춤은 보지 않음) | `FeedbackService.addAccelerometer` |
| `alert` | 이탈 안내 판단 한 번 | `cls`, `conf`, `ang`, `edge`, `msg`/`phase`/`recover`/`edgeTurned`(이번에 고른 문장, 없으면 null), `vib`(진동 여부), `vibAs`(T143: 이미 틀었음 — front + 끝 — 일 때만, 보통 단계 박자로 진동에 쓴 중앙 쪽 방향 left/right. 이때 `vib` 줄은 그 방향 kind에 `lvl` 0) | `feedback_service.dart` `alert` |
| `say` | 음성 요청 | `text`, `p`(0~3 = P0~P3), `act`(speakNow/queue/drop), `why`(§4), `rate`(T124: 빠른 상승 문장일 때만 — 요청한 속도) | `feedback_service.dart` `_speak` |
| `say.end` | 음성 재생이 끝남 | `text`, `p`, `res`(done/cut/timeout/error/superseded), `dur`(ms), `rate`·`rateMs`(T124: 이 발화 전에 속도를 바꿨을 때만 — 바꾼 속도와 `setSpeechRate`에 걸린 ms. 빠른 상승 문장 전의 변경과 다음 발화 전의 복귀가 모두 남는다. `dur`에 포함됨) — 다른 안내가 끊으면 짧게 끝난다. T121: superseded = stop을 기다리는 사이 더 새 발화가 시작돼 speak를 보내지 않음(재생 없음). T132: cut = 재생 중 더 새 발화가 시작돼(stop) 끊김(전에는 done) | `_speak` |
| `say.ttl` | 대기하던 안내가 TTL을 넘겨 버려짐 (T108: 보류한 회복 안내가 2.7초를 넘겨도 / 새 P1을 넣기 전 만료된 대기 항목을 치울 때도) | `text`, `p`, `why`(T126, 대기 슬롯 항목만: `ttl` = TTL 지남 — P0 뒤에서 기다렸으면 마지막 P0 종료부터 / `max_wait` = 처음 요청부터 8초 상한, T130: 진입 안내는 3초) | `_drainPending`, `alert`, `_speak` |
| `flip.hold` | T130: 끝(위치) 판정과 각도 판정이 1초 안에 반대 방향으로 뒤집으려 해서 직전 상태를 유지함 (`EdgeAngleFlipGuard`) — 막은 판정마다 한 줄. **T132: 기본으로 꺼져 있어(`EdgeAngleFlipGuard.enabledByDefault` = false) 나오지 않는다** | `from`(직전 경고 방향), `to`(막은 방향), `src`(막은 판정의 출처: edge = 끝 규칙 / angle = 각도), `ms`(직전 방향에 마지막으로 있던 때부터), `keep`(유지한 상태) | `CameraScreen` 분류·각도·위치 갱신 |
| `say.defer` | 회복 안내를 보류함 (T108 Q1 — front 0.7초 유지 확인 전) / 횡단보도 없음 상태의 멈춤 블록을 1.3초 보류함 (T118) / T131: 끼워 넣은 진입 안내 재생 중이라 이탈·회복 P0를 기다리게 함 (`why`=insert). T132: 바로 재생된 진입 안내 재생 중에도 같다 | `text`, `why`(T131 insert일 때만) | `alert`, `surfaceAlert`, `_speak` |
| `say.force` | T136: 서 있음이 풀린 직후 첫 판정이 같은 방향 이탈이라, 6초 묶음(T120)·서 있음 생략(T133)에 걸리지 않고 방향 경고를 한 번 말함 (뒤이어 같은 문장의 `say`가 나온다) | `text`, `why`(still_off) | `decideMessage` |
| `say.cancel` | 보류·대기 안내를 말하지 않고 취소 | `text`, `why`(flicker = front가 아니게 됨 / superseded = 앞에 횡단보도가 멈춤 블록을 대체 / same_dir = 같은 방향 이탈 경고 6초 묶음으로 생략(T120 — 종전 3초 쿨다운이었다면 말했을 때만, 같은 문장은 3초에 1번 기록) / still = 서 있어서 같은 방향 재경고(6초가 지났고 단계가 같거나 내려감)를 생략(T133, 같은 문장은 3초에 1번 기록) / state = 멈춤 블록 보류가 끝나 말하려 할 때 분류 상태가 none(또는 빈 값)이 아니게 바뀜(T118, `feedback_service.dart` `_holdDotBlock`), 또는 대기 중인 진입 안내가 분류 상태 crossed / none / approach로 취소됨(T130, `cancelPendingEntryOnState`), 또는 T131: 끼운 진입 안내 뒤로 기다리게 한 P0를 내보내려 할 때 분류 상태가 그 P0를 요청할 때와 달라짐(`_releaseInsertHeld`). T131 superseded = 기다리게 한 P0를 더 새 P0가 바꿈) | `alert`, `decideMessage` |
| `chime` | T139: 이탈(left/right)에서 직진(front)으로 돌아온 순간의 '딩' 소리 (복귀 확인 진동 `vib` kind=recover와 함께) | `why`(recover), 재생했으면 `ok`=true / 실패면 `ok`=false·`fail`(tone_unavailable = ToneGenerator를 만들 수 없음, start_failed = 재생 시작 실패, no_channel = 채널 없음, no_player = 재생기 없음, 그 밖 예외 문자열 — 앱은 멈추지 않고 소리 없이 넘어감) / TTS가 말하는 중이라 건너뛰었으면 `skip`=tts. 소리: 안드로이드 ToneGenerator `TONE_PROP_ACK` 300ms, STREAM_MUSIC(`MainActivity.kt`) | `feedback_service.dart` `playRecoverChime` |
| `vib` | 진동 요청 | `kind`(left/right/recover/road/line_on), `ok`, `mode`(pattern/single), `pat`(ms 배열: 대기·켬·끔…) 또는 `why`(no_vibrator). T132: kind가 left/right면 `lvl`(이탈 단계 0 보통·1 즉시·2 가장자리)과 `gap`(적용한 같은 방향 반복 간격 ms: 3000·1500·1000, T136부터 1000·600·400, T139부터 600·350·250). T142: 같은 방향 반복을 경고 호출과 따로 도는 타이머가 울렸으면 `src`=timer(경고 호출로 울린 줄은 `src` 없음, 종전 형식 그대로). T136: left/right `pat`은 좌우 같은 `[0,150]`, 단일 진동으로 내려가면 150ms | `feedback_service.dart` `alert`, `surfaceAlert` |
| `vib.stop` | T142: 같은 방향 반복 진동 타이머를 멈춤 (돌고 있었을 때만 남김) | `why`(state = 상태가 left/right가 아니게 됨 — `to`에 새 상태 / hold = hold 상태(경고 호출 없음) / pause = 앱 일시정지·화면 꺼짐 / dispose = 화면 종료 / stale = 경고 호출이 1초 넘게 없어 울리지 않고 멈춤 — `cls`에 방향) | `FeedbackService.stopDirectionVibration`, `_onDirectionDue` |

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
| `same_p0` | 같은 이탈 문구가 재생 중 (T108) | 버림 |
| `wait_p1` | P1 재생 중에 P1 (T108) | 대기 |
| `supersede_p1` | 앞에 횡단보도가 재생 중인 멈춤 블록을 대체 (T108 Q3) | 즉시 |
| `gap_p1` | 최소 간격 안의 P1 (T108 Q2) | 대기 |
| `slot_full` | 대기 슬롯을 먼저 온 P1이 차지 (T108) | 버림 |
| `after_p0` | 대기하던 진입 안내를 P0가 끝난 직후 최소 간격 없이 끼워 넣음 (T131) | 즉시 |
| `p0_cut` | 대기하던 진입 안내를, 재생 중인 P0가 다른 P0에 끊기는 순간 끼워 넣음 — 끊으려던 P0는 `say.defer` why=insert로 기다림 (T132 ①) | 즉시 (재생 중인 P0를 끊음) |

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

- 녹화 파일 이름의 시각(폰 시계, 초 단위)은 녹화 **종료**(저장) 시각이다. 시작 = 이름 시각 − 영상 길이 + 0.75초(추정, ±0.25초).
  - 근거(2026-10-02): 상태 표시줄 분이 바뀌는 프레임으로 역산. `131012` 시작 13:09:22.43~23.0, `205033` 시작 20:49:47.0~47.5. 이 기준으로 `130851` 화면 판정 전환 9개가 기록 상태 전환과 1초 안에서 일치했다.
- 기록의 음성 시작 시각과 영상 소리의 시작 시각을 맞춰 오프셋을 찾는다(±8초 범위, 0.3초 허용).
  - 3개 이상 맞으면 그 오프셋을 쓴다.
  - 아니면 파일 이름 시각만 쓴다(1초 안팎 오차 가능, 추정).
- 화면 녹화의 소리 설정이 "미디어 소리"여야 소리로 맞출 수 있다.
- 프레임은 요청 시각까지 차례로 읽어서 뽑는다. 9/29 녹화 실측 오차는 최대 0.038초다(키프레임 탐색만 하면 0.61초).

## 8. 프레임 저장 (B안 ①, 사용자 결정 2026-10-21)

설계: `train/phone_ultrawide/design.md` §3 ①(d). 코드: `crosswalk_app/lib/services/dev_capture.dart` `FrameSaver`.

| 항목 | 값 |
|---|---|
| 켜는 곳 | 설정 › 개발용 수집 (초광각) › **프레임 저장**. 기본 꺼짐, 앱을 다시 켜면 꺼짐 |
| 무엇 | 분류기가 224로 줄이기 직전의 센서 프레임 그대로(원본 해상도, **회전 없음**). 모델별 입력은 `frame.rot`·`frame.crot`로 다시 만든다 |
| 주기 | 1초에 1장 (이전 장을 아직 쓰는 중이면 그 초는 건너뜀) |
| 형식 | JPEG 품질 90. 인코딩은 별도 isolate |
| 위치 | 앱 전용 폴더 `getApplicationSupportDirectory()/frames/<켠 시각 YYYYMMDD_HHMMSS>/` (다른 앱은 못 읽음) |
| 이름 | `f_<t>.jpg` — `t`는 기록 `t`와 같은 폰 시계 epoch ms(프레임을 받은 시각) |
| 크기 상한 | 모든 묶음 합계 500MB. 넘으면 오래된 것부터 지움 |
| 밖으로 | 설정의 **프레임 보내기 (최근 묶음)** → 안드로이드 공유 창. 앱에 인터넷 권한 없음 |
| 예상 크기 | 720×480 기준 장당 약 50~100KB → 20분 약 60~120MB (추정, 첫 기록 `frame.kb`로 확인) |
