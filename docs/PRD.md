# PRD — crosswalk_app (횡단보도 이탈 감지)

Owner: planner (see AGENTS.md). Others read-only.
Last updated: 2026-08-22 (5-class 클래스 정의 사용자 확정 — §클래스 정의 절 신설, Open Q #16 추가; 후속 태스크 T50/T51/T52 등록). Also 2026-08-22 (data-leak discovery + leak-free GroupKFold re-measurement; corrected the prior "TARGET NOT MET" assertion to "판정 불가"). Prior: 2026-07-18 (added Open Q #15 — chest-mount camera tilt/height, from Architecture §16.6 Open Question D); 2026-07-16. Basis: code inspection of `crosswalk_app/lib/`, `crosswalk_app/pubspec.yaml`, `.github/workflows/build_apk.yml`, `train/`, `model/`, and git history (`develop`).

> **2026-08-22 정정 고지 (중요):** 2026-07-17 / 2026-08-02 / 2026-08-21 측정값은 모두 **데이터 누수 위에서 나온 값**으로 신뢰할 수 없습니다. 이력 보존을 위해 삭제하지 않고 남기되, 모두 "누수 있음"으로 표시했습니다. 현재 권위 있는 값은 2026-08-22 GroupKFold 측정(§Model Accuracy)뿐입니다.

> Status legend: 구현됨 = implemented (evidence in code), 부분구현 = partial, 미구현 = not implemented, 추정 = inferred (not confirmable from code — see Open Questions).

## Goal
On-device (offline, 추정) mobile app that warns a visually impaired user in real time, via voice + vibration, when they drift left/right off a crosswalk while crossing.
Evidence: `pubspec.yaml:2` (description), `ARCHITECTURE.md:3`, `crosswalk_app/lib/services/feedback_service.dart:30-38`.

## 제품 형태 (2026-08-23 사용자 확정)

**최종 목표는 전용 하드웨어 기기다.** 스마트폰 앱은 없어지지 않는다 — **병행 제품으로 존재하거나,
하드웨어와 연동되는 형태**로 남는다. (사용자 확정, 2026-08-23)

하드웨어는 **아직 구상 단계**다. 카메라 모듈·렌즈 화각·장착 각도/높이 중 무엇도 정해지지 않았다.

이 결정이 지금 작업에 주는 영향 — 무엇이 유지되고 무엇이 조건부인가:

| 항목 | 하드웨어 전환 시 |
|---|---|
| 세션 단위 누수 없는 평가 방법론 | 유지 (카메라와 무관) |
| 5-class 정의·판정 기준 | 유지 (문제 정의) |
| 손실가중 이중 보정 결론 (T53) | 유지 (학습 절차의 성질) |
| 라벨↔모델 동기화 검증 (T54) | 유지 |
| 224px 캐시 (T56) | 유지 |
| EXIF Orientation 정렬 (T57) | **유지** — 앱이 병행 제품이므로 여전히 필요 |
| 세로 촬영 원칙 | **앱 기준으로는 유지.** 하드웨어는 케이스를 직접 만들므로 자유 선택 |
| 현재 637장 데이터 | **앱에는 그대로 유효.** 하드웨어 카메라가 정해지면 도메인 격차만큼 재수집/파인튜닝 필요 |

데이터가 버려지지 않는 이유: 앱이 병행 제품이므로 폰 카메라 데이터는 그 자체로 제품용이다.
다만 하드웨어 카메라가 폰과 화각이 크게 다르면 그 기기용으로는 추가 수집이 필요하다 —
**얼마나 필요한지는 카메라가 정해지기 전에는 추정조차 불가능하다.**

하드웨어 쪽의 기회 (미검증, 구상 단계이므로 설계 입력으로만 기록):
현재 `right` 실패의 가장 큰 원인이 "횡단보도 좌우 경계가 프레임 밖"이다. 폰 화각 약 68도,
가슴 높이 1.3m 가정 시 지면 촬영 폭 약 1.75m인데 횡단보도 폭은 통상 4m 이상이라, 중앙에 서면
경계가 양쪽 다 화면 밖이다. 하드웨어는 **광각 렌즈를 선택할 수 있으므로** 폰에서 못 고치던 이
기하학적 한계를 부품 선택으로 완화할 수 있다.


## Target Users
- Primary: visually impaired pedestrians crossing at crosswalks. Evidence: `pubspec.yaml:2`, `feedback_service.dart` (ko-KR voice guidance).
- Deployment target platform(s): Android + iOS (Open Q #1, ANSWERED 2026-07-17). Min OS: Android minSdk 26; iOS minimum iOS 15 (Open Q #2, ANSWERED 2026-07-17). Distribution channel: undecided (Open Q #7).

## Core Features — Status Table

| # | Feature | Status | Evidence |
|---|---|---|---|
| 1 | Live rear-camera frame stream (YUV420, medium res, portrait-locked, audio off) | 구현됨 | `camera_screen.dart:95-107`, `main.dart:7` |
| 2 | ONNX Runtime on-device inference (3-class: front/left/right) | 구현됨 | `classifier.dart:22,37-43,79` |
| 3 | Frame preprocessing: YUV420/BGRA → RGB → 224×224 → NCHW + ImageNet norm | 구현됨 | `classifier.dart:113-175` |
| 4 | Inference throttling (every 5th frame) | 구현됨 | `classifier.dart:31,68-69` |
| 5 | Probability smoothing over last 5 frames | 구현됨 | `classifier.dart:24,90-98` |
| 6 | Asymmetric confidence thresholds (front 0.85 strict / deviation 0.55 sensitive) | 구현됨 | `classifier.dart:27-28,107-108` |
| 7 | Voice (TTS ko-KR, rate 0.5) + vibration (500ms) deviation alerts | 구현됨 | `feedback_service.dart:11-39` |
| 8 | Alert cooldown (3s per same class; new class alerts immediately) | 구현됨 | `feedback_service.dart:9,20-28` |
| 9 | Status overlay UI (color + icon + text + confidence %) | 구현됨 | `camera_screen.dart:26-42,231-258` |
| 10 | Error handling: camera permission denied / no camera / model corrupt / generic, with red overlay + spoken error + retry button | 구현됨 | `camera_screen.dart:62-129,202-278` |
| 11 | Screen wakelock + app-lifecycle camera release/reinit | 구현됨 | `camera_screen.dart:48,150-166` |
| 12 | Model integrity check (SHA-256) | 부분구현 (disabled: app asset hash is `placeholder_hash`) | `classifier.dart:45-65`, `assets/model/crosswalk_model.onnx.sha256:1` |
| 13 | CI: GitHub Actions APK build + conditional signing | 구현됨 | `.github/workflows/build_apk.yml` |
| 14 | Model training pipeline (MobileNetV3-Small, 3-class, ONNX export) | 구현됨 (scripts + artifacts present) | `train/train_model.py`, `model/crosswalk_model.onnx`, `model/crosswalk_model.pt` |
| 15 | Positive "on-track" reassurance feedback (front) | 미구현 (front intentionally silent) | `feedback_service.dart:18` |
| 16 | Onboarding / settings / calibration screen | 미구현 | only `CameraScreen` exists (`main.dart:20`) |
| 17 | Multi-language voice guidance | 미구현 (hardcoded ko-KR) | `feedback_service.dart:12,30-32` |
| 18 | Native screen-reader (TalkBack/VoiceOver) Semantics integration | 미구현 (custom TTS only, no `Semantics` widgets) | `camera_screen.dart` (no Semantics) |
| 19 | Automated tests (unit/widget/integration) | 미구현 (no `crosswalk_app/test/`) | glob: no test dir |
| 20 | Low-light / night / adverse-weather handling | 미구현 | no code path found |
| 21 | Analytics / crash logging / telemetry | 미구현 | no code found |

## Non-Functional Requirements

| Area | Current state (evidence) | Target |
|---|---|---|
| Offline operation | No network calls in `lib/` (fully on-device today). | v1 offline; online components may be added later (Open Q #4, ANSWERED 2026-07-17 — not a permanent fully-offline constraint). |
| Performance | Throttle=5 → ~6fps@30fps (`classifier.dart:30`); YUV→RGB is per-pixel Dart loop on UI isolate (`classifier.dart:132-148` runs in `_onFrame`, no isolate) | Still undefined; to be decided after real-device testing (Open Q #11). |
| Accessibility | Custom Korean TTS + vibration; no native Semantics; high-contrast dark UI | Standard to meet still undecided (Open Q #5). |
| Safety (false-negative risk) | Training weights left=10/right=20 vs front=1 (`ARCHITECTURE.md:77`); deviation threshold lowered to 0.55. **AUTHORITATIVE = 2026-08-22 leak-free GroupKFold measurement — see §Model Accuracy below. left recall 87.5% CI [80.2%, 94.2%], right recall 90.7% CI [85.5%, 95.3%] → 두 CI 모두 90%를 포함하므로 목표 달성 여부는 현재 데이터로 판정 불가 (미달일 수도, 달성했을 수도 있음).** 이전의 2026-07-17 측정(누수 있음)은 §Model Accuracy의 이력 표에 보존. | Deviation recall ≥ 90% / miss rate ≤ 10% (Open Q #3, ANSWERED 2026-07-17). **판정 불가 (NOT "미달")** — 이전 서술의 "TARGET NOT MET" 단언은 표본 크기를 고려하지 않은 것으로 2026-08-22에 정정됨. 판정 확정에는 촬영 세션 다양성 확대가 필요(T44 — 기준은 "장수"가 아니라 "서로 다른 장소·다른 날의 세션 수"). Front false-positive tolerance는 여전히 미정 — 이제 오경보 실재(10.1%)가 확정되어 정할 근거가 생김(Open Q #3 참조, T49). |
| Model provenance | App-bundled `crosswalk_model.onnx` present; integrity hash is placeholder → verification effectively off | Confirm real vs dummy model → Open Q #10 |

## Model Accuracy (측정 이력 및 현재 권위 값)

### 데이터 누수 발견 (2026-08-22) — 이전 측정 전부 무효화
- 843장 중 **789장(93.6%)이 연속 촬영 그룹**에 속함.
- 파일명에 `_saved`가 붙은 **245장**은 앱이 카메라 프레임을 자동 저장한 연사 프레임. 64×64 그레이스케일 평균 픽셀차가 **2.2~8.5**(일반 사진끼리는 **23~45**) — 사실상 같은 사진. 바이트 완전 복제는 **0건**이나 시각적으로 중복.
- `train/train_model.py`의 `prepare_data()`가 **무작위 셔플로 분할**하므로, `_001`로 학습한 모델이 `_002`로 평가받는 누수가 발생.
- **누수 크기** (같은 데이터·같은 학습설정, 분할 방식만 다름): 무작위 k-fold가 front recall을 **13.3%p 부풀림**(92.8% vs 79.5%), front 오경보를 **2.8배 축소**(3.6% vs 10.1%).

### 측정 이력 — 신뢰성 표시

| 측정일 | 분할 방식 | 누수 여부 | 상태 |
|---|---|---|---|
| 2026-07-17 (T1, `train/eval_model.py`) | 무작위 | **누수 있음** | **신뢰 불가.** 기록만 보존: left recall 83.3% (5/6), right recall 100% (3/3, n=3), front recall 70.0% (35/50), front 오경보 14% (7/50, →left 4 / →right 3). 표본이 극히 작음. |
| 2026-08-02 | 무작위 | **누수 있음** | **신뢰 불가.** 상세 수치는 `docs/Tasks.md` 이력 참조. |
| 2026-08-21 (2회) | 무작위 | **누수 있음** | **신뢰 불가.** 상세 수치는 `docs/Tasks.md` 이력 참조. |
| 2026-08-22 (`train/groupkfold_cv.py`) | 세션 단위 GroupKFold | 누수 없음 | **현재 권위 값 (아래).** |

### 현재 권위 값 — 2026-08-22 leak-free GroupKFold
방법: `train/groupkfold_cv.py`. EXIF `DateTimeOriginal`(843장 전부 보유) 기준 **60초 간격으로 147개 세션** 분할, 세션을 통째로 fold에 배정. 근사 중복 클러스터도 fold를 넘지 않음. 분할 직후 **assert로 강제 검사**(위반 시 즉시 중단), 실행 시 통과. **5-fold**, 근사 중복 클러스터당 1장 집계(**768장**).

| 지표 | 점추정 | 95% CI (클러스터 부트스트랩) |
|---|---|---|
| front recall | 79.5% (213/268) | [71.8%, 86.1%] |
| left recall | 87.5% (105/120) | [80.2%, 94.2%] |
| none recall | 87.8% (201/229) | [82.9%, 91.4%] |
| right recall | 90.7% (137/151) | [85.5%, 95.3%] |
| front 오경보 (직진을 left/right로 오판) | 10.1% (27/268) | [4.3%, 17.4%] |

- CI는 **클러스터 부트스트랩(세션 단위 재표본 10000회)이 정본**. Wilson 구간은 이미지 독립을 가정하는데 같은 세션 이미지들은 상관되어 있어 실제보다 좁게 나옴.

### 목표 판정 (deviation recall ≥ 90%, Open Q #3)

| 클래스 | 점추정 | 95% CI | 판정 |
|---|---|---|---|
| left | 87.5% | [80.2%, 94.2%] | **판정 불가** (CI가 90%를 포함) |
| right | 90.7% | [85.5%, 95.3%] | **판정 불가** (CI가 90%를 포함) |

**정정 (2026-08-22):** 이전 PRD 서술은 "TARGET NOT MET"이라 단언했으나, 이는 표본 크기를 고려하지 않은 것이었음. 정확한 표현은 **"현재 데이터로는 판정 불가"** — 미달일 수도, 달성했을 수도 있음. 판정을 확정하려면 촬영 세션 다양성 확대가 필요 (`docs/Tasks.md` T44 — 기준은 "장수"가 아니라 **서로 다른 장소·다른 날의 세션 수**).

## Dataset 현황 (2026-08-22)
- 총 **843장** — front 332 / left 127 / right 155 / none 229.
- 근사 중복 제거 시 **768장** — front 268 / left 120 / right 151 / none 229.
- **147개 촬영 세션**, 촬영 기간 2025-11-19 ~ 2026-08-19 (**23일**).
- 날짜 편중: 2025-11-19 **279장(33%)**, 2026-07-31 **178장(21%)**.

## 클래스 정의 (2026-08-22 사용자 확정 — 현재 권위 값)

> 이 절이 클래스 정의의 **현재 권위 값**입니다. 이 문서의 다른 곳(§Core Features 표 2번·14번 행의 "3-class", §Model Accuracy·§Dataset 현황의 front/left/right/none 4-class 서술 등)에 남아 있는 3-class·4-class 기술은 **2026-08-22 이전 이력**이며, 이력 보존을 위해 삭제하지 않고 그대로 둡니다. 앞으로의 라벨링·학습·앱 코드는 아래 5-class 정의를 따릅니다.

### 확정 정의 (5-class)

| 클래스 | 정의 |
|---|---|
| `front` | 횡단보도가 화면 아래에서 시작해 앞으로 뻗고, 진행 방향이 횡단보도 축과 정렬됨 |
| `left` | 위 조건(횡단보도 위) + 축에서 왼쪽으로 벗어남 |
| `right` | 위 조건(횡단보도 위) + 축에서 오른쪽으로 벗어남 |
| `approach` | **신설.** 횡단보도가 앞쪽에 보이지만 아직 그 위가 아님 (인도·연석 위, 대기 중) |
| `none` | 횡단보도가 없는 곳 |

### 판정 기준 (사진만으로 판정 가능해야 함)
- 횡단보도 줄무늬가 **화면 아래에서 시작하면** "위에 있음" → `front` / `left` / `right`.
- 횡단보도가 **앞쪽에 떨어져 있고 그 사이에 인도·연석이 보이면** → `approach`.
- 촬영 당시의 실제 위치가 아니라 **사진에서 판정 가능한 기준**을 쓴다. 이유: 다른 사람이 같은 사진을 봐도 같은 답이 나와야 하기 때문.

### 결정 근거 (2026-08-22)
기존 `front` 클래스가 **성격이 다른 두 상황을 섞고 있었음**이 통계적으로 확인됨.

| 항목 | 값 |
|---|---|
| 오경보 27건 중 "인도 위에서 촬영" | 12건 (44.4%) |
| 정상 판정 대조군 27건 중 "인도 위에서 촬영" | 1건 (3.7%) |
| 오즈비 | 20.8 |
| Fisher 정확검정 (양측) | p = 0.00088 |
| 세션 군집 보수적 반영 시 (오경보군 6/13 가정) | p = 0.0026 — 결론 유지 |

원인: 인도에서 본 횡단보도는 카메라 축과 횡단보도 축이 어긋나 **기하학적으로 실제 이탈과 구별되지 않음.** 즉 모델 결함이 아니라 **학습 데이터가 모순된 것을 가르치고 있었음.**

### 앱 동작
- `approach`는 현재로선 `none`과 **동일하게 침묵**한다. 따라서 이번 정의 변경으로 **사용자가 겪는 동작은 바뀌지 않는다.**
- `approach`를 별도 클래스로 두는 이유는 나중에 "횡단보도 앞입니다" 같은 **진입 안내를 추가할 여지**를 남기기 위함이다.

### 후속 작업
- 재라벨링: `docs/Tasks.md` **T50** (P0)
- 앱·학습 코드 5-class 대응: `docs/Tasks.md` **T51** (P0, T50 의존) — 라벨 인덱스 전면 이동 위험 포함

## Known Documentation Drift (evidence-based, not requirements)
`ARCHITECTURE.md` is stale vs current code — flag for docs agent, not a code change:
- Throttle: doc says 10 (`ARCHITECTURE.md:174,196`); code is 5 (`classifier.dart:31`).
- Threshold: doc says single 0.70 (`ARCHITECTURE.md:172,189`); code uses 0.85/0.55 (`classifier.dart:27-28`).
- Init order: doc says permission→model→TTS (`ARCHITECTURE.md:127-137`); code is TTS→permission→model (`camera_screen.dart:60-75`).
- `export_onnx.py` described (`ARCHITECTURE.md:90`) — **correction**: an earlier pass of this doc claimed it was "absent from `train/`"; that was wrong. `train/export_onnx.py` exists (25 lines) as a standalone re-export script separate from `train_model.py`'s embedded exporter; it is the script whose settings (opset 12, `dynamo=False`) match the currently-shipped model's verified `ir_version=7`/`opset=12`. Full trace: `docs/Architecture.md` §11.1/§11.2.

## Out of Scope (current build)
- iOS build/signing (CI produces APK only). NOTE: iOS is now an in-scope target platform (Open Q #1 ANSWERED 2026-07-17), but no iOS build/signing pipeline exists yet — building it is tracked as T33, not part of the current build.
- GPS/location, traffic-signal detection, obstacle detection.
- `crosswalk_app_scaffold/` — was default Flutter counter-app boilerplate, unused; DELETED from the filesystem (T20, 2026-07-17). It was never tracked by git (`.gitignore:18`), so there is no commit/diff for the removal — pure local cleanup. The directory no longer exists.

## Assumptions (推定 — verify before building on them)
- v1 runs offline on-device; online components may be added later (Open Q #4, ANSWERED 2026-07-17 — no longer a fixed fully-offline assumption).
- Rear camera only (Open Q #14, ANSWERED 2026-07-17), chest-mounted (lanyard/chest-mount) facing the crosswalk ahead (Open Q #8, ANSWERED 2026-07-17). Frame-interpretation/preprocessing may need re-review against this posture — see T35.
- Multilingual support required (Open Q #6, ANSWERED 2026-07-17) — the prior "Korean-only for v1" assumption is retired. Supported languages fixed (user, 2026-07-17) = 한국어 (Korean) + 영어 (English), two languages only. Concrete locale codes and translated strings are implementation-stage decisions (see T17/T34). Current code hardcodes ko-KR (see T34).

## Risks
| Risk | Impact | Mitigation |
|---|---|---|
| False negative (miss a deviation) | High (user safety) | Recall target ≥ 90% / miss ≤ 10% set (Open Q #3, ANSWERED 2026-07-17). **MEASURED 2026-08-22 (leak-free GroupKFold): left 87.5% CI [80.2%, 94.2%], right 90.7% CI [85.5%, 95.3%] → 목표 달성 여부 판정 불가** (두 CI 모두 90%를 포함). 이전의 "FAILS/미달" 단언은 2026-08-22 정정됨. 2026-07-17 값(left 83.3%, right n=3)은 **누수 있음 → 신뢰 불가**, 이력으로만 보존. 판정 확정 경로: 촬영 세션 다양성 확대(T44) 후 재측정. 참고로 편향 미검출은 전부 임계값 미달에 의한 무판정(침묵)으로 나타나 상대적으로 안전한 실패 양상. |
| False alarm (spurious deviation warning while walking straight) | Med–High (user trust / safety — 직진 중인 사용자에게 허위 이탈 경고를 보내 시각장애인을 위험한 방향으로 유도할 수 있음) | **실재 확정으로 격상 (2026-08-22).** leak-free GroupKFold 측정: **10.1% (27/268), CI [4.3%, 17.4%]** — **CI 하한 4.3%가 0을 명확히 배제하므로 실재하는 문제로 확정**, 소표본 착시가 아님. 다만 크기는 4~17%로 아직 정밀하지 않음. 이전 2026-07-17 값 14% (7/50)은 **누수 있음 → 신뢰 불가**, 이력으로만 보존. 조사 태스크는 `docs/Tasks.md` **T49 (P1)** 로 등록되어 있고 판정표·실행계획이 착수 전에 확정·기록됨. front false-positive 허용치는 **여전히 미정** — T49의 임계값 스윕 결과를 사용자에게 제시해 결정 예정(임의로 정하지 않음). |
| Per-pixel YUV→RGB on UI thread may drop frames on low-end devices | Med (latency) | Define perf target + device tier (Open Q #11); consider isolate/native conversion |
| Integrity check disabled (placeholder hash) | Med (tampered model shipped silently) | Populate real SHA-256 in build (T-prefixed task) |
| No tests | Med (regressions) | Add unit tests for classifier/feedback logic |
| Liability of guiding blind users across roads | High (legal) | Disclaimer required at onboarding/first launch (Open Q #9, ANSWERED 2026-07-17) — implement via T36 |

## Open Questions (require human decision — not guessed)
| # | Question | Status |
|---|---|---|
| 1 | Target platform(s): Android only, or iOS too? (CI=APK only; BGRA path hints iOS) | ANSWERED (user, 2026-07-17): BOTH Android and iOS. NOTE: no iOS build/signing pipeline exists yet (CI is Android/APK-only) — see Out of Scope; new task candidate T33 (iOS build/signing pipeline). |
| 2 | Minimum supported OS versions (Android minSdk / iOS target)? | ANSWERED (user, 2026-07-17): Android minSdk 26 (Android 8.0); iOS minimum = iOS 15. Both parts now decided. NOTE: reflecting these values in the actual project config (Android Gradle minSdk, iOS deployment target in the Xcode/Runner project) is separate implementer work — Android config under T2; iOS config work is coupled to the iOS build/signing pipeline (T33), which is currently PAUSED (see T33). |
| 3 | Required accuracy — acceptable false-negative (missed-deviation) rate / recall target for left/right? | **ANSWERED (user, 2026-07-17) — 유지**: deviation (left/right) detection target recall ≥ 90%, i.e. false-negative rate ≤ 10%. **현재 달성 여부는 아직 판정 불가** (2026-08-22 leak-free 측정: left 87.5% CI [80.2%, 94.2%], right 90.7% CI [85.5%, 95.3%] — 두 CI 모두 90%를 포함). 판정 확정에는 촬영 세션 다양성 확대(T44)가 필요. **하위 항목 3a는 여전히 OPEN** — 아래 참조. |
| 3a | Front (직진) 오경보 허용치는 몇 %인가? (Open Q #3의 미결 하위 항목 — 2026-07-17 이후 계속 미정) | **OPEN — 임의로 정하지 않음.** 2026-07-17에 사용자가 이 값을 제시하지 않아 미정으로 남았고 현재도 미정. 변화: 2026-08-22 leak-free 측정에서 front 오경보 **10.1% (27/268), CI [4.3%, 17.4%]** 로 **실재함이 확정**(CI 하한이 0을 배제)되어, 이제 이 값을 정할 근거가 생김. 결정 방법: **T49의 임계값 스윕 결과를 사용자에게 제시해 사용자가 결정**. |
| 4 | Confirm fully offline; any online component ever intended? | ANSWERED (user, 2026-07-17): NOT confirmed as permanently fully offline. v1 is offline, but "추후 온라인 요소 추가 가능성 있음" (online components such as server communication / remote logging may be added in the future). So "fully offline" is not a fixed constraint. |
| 5 | Accessibility standard to meet (WCAG level? native TalkBack/VoiceOver compatibility required)? | open (user re-confirmed, 2026-07-17: 아직 미정 / still undecided). **ANSWERED (user, 2026-07-24)**: TalkBack/VoiceOver 실사용 호환성만 확보 — 공식 WCAG 인증 수준은 요구하지 않음. 표준 선택 자체는 완료; 준수 체크리스트 작성 및 실제 Semantics 구현은 별도 구현 작업(T3/T16)으로 남음. |
| 6 | Supported languages — Korean only or multilingual? | ANSWERED (user, 2026-07-17): multilingual required (not Korean-only). Supported language list fixed (user, 2026-07-17) = 한국어 (Korean) + 영어 (English) — exactly two languages. Concrete locale codes / translated strings are decided at implementation time (T17/T34), not here. NOTE: `feedback_service.dart` currently hardcodes ko-KR — see T34 (multi-language support). |
| 7 | Distribution & monetization (Play Store? free? app branding/identity)? | open (user re-confirmed, 2026-07-17: 아직 미정 / still undecided). |
| 8 | Intended phone posture/mounting (handheld, chest-mount, lanyard)? Needs user guidance? | ANSWERED (user, 2026-07-17): chest-mount (목걸이/가슴대, lanyard/chest-mount) assumed. NOTE: this camera angle differs from the prior "handheld facing ahead" assumption; frame-interpretation/preprocessing may need re-review for this posture — see new task candidate T35. |
| 9 | Legal safety disclaimer / scope-of-use statement required in-app? | ANSWERED (user, 2026-07-17): required — a disclaimer must be shown at onboarding / first launch. NOTE: no onboarding screen exists yet — see new task candidate T36 (onboarding + disclaimer). |
| 10 | Is the committed `crosswalk_model.onnx` the real trained model or a dummy? (asset hash = placeholder) | ANSWERED (user, 2026-07-17): genuinely the real trained-model output, NOT a dummy — independently verified byte-for-byte identical to `model/crosswalk_model.onnx` (the training pipeline's actual output file, `cmp` confirmed, 6,098,102 bytes). CAVEAT (user): training may not be complete/final — this could be an intermediate checkpoint rather than the final production-quality model. REASON (user, 2026-07-17): current training data is insufficient in volume/coverage; a retraining pass with more data is planned for later. This does NOT block enabling integrity verification (T7) or confirming asset provenance (T8), since both only require the committed file to genuinely be pipeline output (now confirmed) — but it DOES mean Open Question #3 (accuracy/recall target) cannot yet be validated against this specific model with confidence that it represents final quality, and any future model replacement (once retraining with more data completes) will require regenerating the SHA-256 hash (T7) and re-verifying the byte-match (T8) against the new final checkpoint. |
| 11 | Performance targets: min FPS, alert latency, battery budget, minimum device tier? | open (user re-confirmed, 2026-07-17: 아직 미정 — to be decided after on-device/real-device testing). **PARTIALLY ANSWERED (user, 2026-07-24)**: minimum device tier = 기존 결정된 minSdk 기준 그대로(Android 8.0/minSdk26, iOS 15 — Open Q #2와 동일, 저사양 기기 포함); battery budget = 1시간 연속 사용 시 배터리 소모 10% 이내. min FPS / alert latency는 사용자가 "선호 없음"으로 답해 여전히 open — 기존 방침대로 실기기 테스트 후 결정. 4개 하위 항목 중 2개만 확정. |
| 12 | Behavior under low-light/night/rain/occlusion — in scope for v1? | ANSWERED (user, 2026-07-17): low-light/night IS in scope for v1, with improvement needed later. No low-light handling exists in code today — see new task candidate T37. (rain/occlusion not separately addressed by the user.) |
| 13 | Provide periodic positive "on-track" reassurance, or stay silent on front? | ANSWERED (user, 2026-07-17): stay silent on front (keep current behavior). No code change needed. |
| 14 | Camera choice — rear assumed; any front-camera or dual use case? | ANSWERED (user, 2026-07-17): rear camera only (keep current behavior). No code change needed. |
| 15 | 가슴착용 카메라의 정확한 틸트 각도/장착 높이는? (Exact chest-mount camera tilt/pitch angle and mount height) — raised by architect in T35, `docs/Architecture.md` §16.6 Open Question D, because training data was captured with a steep downward ground-view framing (§16.2) that does not match the confirmed chest-mount forward posture (Open Q #8); the size of that mismatch depends on this unstated tilt angle. | ANSWERED — DIRECTION ONLY, NOT A PRECISE SPEC (user, 2026-07-18): 사용자는 "정면에 가깝게, 약간 아래로 기울어질 것 같아"라고 답함 — 즉 가슴착용 시 카메라가 수평(정면)에 가깝되 약간 아래를 향할 것으로 **예상/추정**한다는 정성적 방향성만 제시. 사용자 스스로 "~것 같아"라는 추정성 어투로 답했으므로 이는 실측값이 아님. **정확한 각도(도° 단위)와 장착 높이는 여전히 미정** — 정밀 재현이 필요하면 실측 또는 사용자의 추가 확정이 필요. Related: Open Q #8, #10; Tasks T1, T35. |
| 16 | 클래스 체계 — 기존 `front`가 "횡단보도 위 직진"과 "인도에서 대기 중"을 섞고 있는데, 이를 어떻게 나눌 것인가? | **ANSWERED (user, 2026-08-22): 5-class 체계로 확정** — `front` / `left` / `right` / `approach`(신설) / `none`. 정의·판정 기준·결정 근거(Fisher 정확검정 p=0.00088, 오즈비 20.8)·앱 동작(`approach`는 `none`과 동일하게 침묵)은 위 **§클래스 정의 (2026-08-22 사용자 확정)** 에 기록됨. 판정 기준은 촬영 당시 실제 위치가 아니라 **사진만으로 판정 가능한 기준**을 쓰기로 확정. 남은 작업은 결정이 아니라 실행 — 재라벨링 T50, 코드 대응 T51. **주의: 이 답변은 Open Q #3a(front 오경보 허용치)를 해소하지 않음** — #3a는 여전히 OPEN. |
| 17 | 하드웨어 기기와 스마트폰 앱의 역할 분담 — 추론은 어디서 도는가(기기 내장 / 폰), 둘 사이 통신은 무엇인가(BLE/Wi-Fi/유선), 모델을 공유하는가 아니면 각자 최적화하는가? | open (2026-08-23 제기). 하드웨어가 구상 단계라지금 답할 수 없으나, **카메라 모듈·렌즈 화각·장착 각도/높이보다 먼저 답할 필요는 없다.** 데이터 수집 계획을 좌우하는 것은 카메라 사양이므로 그쪽이 선행이다. 이 질문은 아키텍처 문서 재작성 시점의 선행 조건으로 기록해 둔다. |
| 18 | 하드웨어 카메라 사양(모듈·렌즈 화각·장착 각도/높이) — 무엇으로 확정하는가? | open (2026-08-23 제기). **대규모 데이터 수집을 막고 있는 실질적 병목.** 카메라가 정해지기 전에 그 기기용 데이터를 수백 장 모으면 화각이 다를 경우 노동이 버려진다. 권고 순서: (1) 카메라·렌즈·장착 각도 확정 -> (2) 그 카메라로 20~30장 시험 촬영해 좌우 판별이 사람 눈으로 가능한지 확인 -> (3) 본격 수집. 앱용 폰 데이터 수집은 이 질문과 무관하게 계속 유효하다(앱이 병행 제품이므로). |
