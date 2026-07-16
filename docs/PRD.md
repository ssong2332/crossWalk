# PRD — crosswalk_app (횡단보도 이탈 감지)

Owner: planner (see AGENTS.md). Others read-only.
Last updated: 2026-07-16. Basis: code inspection of `crosswalk_app/lib/`, `crosswalk_app/pubspec.yaml`, `.github/workflows/build_apk.yml`, `train/`, `model/`, and git history (`develop`).

> Status legend: 구현됨 = implemented (evidence in code), 부분구현 = partial, 미구현 = not implemented, 추정 = inferred (not confirmable from code — see Open Questions).

## Goal
On-device (offline, 추정) mobile app that warns a visually impaired user in real time, via voice + vibration, when they drift left/right off a crosswalk while crossing.
Evidence: `pubspec.yaml:2` (description), `ARCHITECTURE.md:3`, `crosswalk_app/lib/services/feedback_service.dart:30-38`.

## Target Users
- Primary: visually impaired pedestrians crossing at crosswalks. Evidence: `pubspec.yaml:2`, `feedback_service.dart` (ko-KR voice guidance).
- Deployment target platform(s), min OS, distribution channel: NOT decidable from code → Open Questions #1, #2, #7.

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
| Offline operation | No network calls in `lib/` (fully on-device). 추정 intended offline. | Confirm → Open Q #4 |
| Performance | Throttle=5 → ~6fps@30fps (`classifier.dart:30`); YUV→RGB is per-pixel Dart loop on UI isolate (`classifier.dart:132-148` runs in `_onFrame`, no isolate) | No FPS/latency/battery target defined → Open Q #11 |
| Accessibility | Custom Korean TTS + vibration; no native Semantics; high-contrast dark UI | Standard to meet undefined → Open Q #5 |
| Safety (false-negative risk) | Training weights left=10/right=20 vs front=1 (`ARCHITECTURE.md:77`); deviation threshold lowered to 0.55 | No measured recall target → Open Q #3 |
| Model provenance | App-bundled `crosswalk_model.onnx` present; integrity hash is placeholder → verification effectively off | Confirm real vs dummy model → Open Q #10 |

## Known Documentation Drift (evidence-based, not requirements)
`ARCHITECTURE.md` is stale vs current code — flag for docs agent, not a code change:
- Throttle: doc says 10 (`ARCHITECTURE.md:174,196`); code is 5 (`classifier.dart:31`).
- Threshold: doc says single 0.70 (`ARCHITECTURE.md:172,189`); code uses 0.85/0.55 (`classifier.dart:27-28`).
- Init order: doc says permission→model→TTS (`ARCHITECTURE.md:127-137`); code is TTS→permission→model (`camera_screen.dart:60-75`).
- `export_onnx.py` described (`ARCHITECTURE.md:90`) but absent from `train/` (only `train_model.py`, `convert_to_tflite.py`).

## Out of Scope (current build)
- iOS build/signing (CI produces APK only; BGRA preprocessing path exists but no confirmed iOS target — Open Q #1).
- GPS/location, traffic-signal detection, obstacle detection.
- `crosswalk_app_scaffold/` — default Flutter counter-app boilerplate, unused (`crosswalk_app_scaffold/lib/main.dart:1-15`).

## Assumptions (推定 — verify before building on them)
- App is meant to run fully offline on-device.
- Rear camera held/mounted facing the crosswalk ahead; exact mounting posture unspecified (Open Q #8, #14).
- Korean-only user base for v1.

## Risks
| Risk | Impact | Mitigation |
|---|---|---|
| False negative (miss a deviation) | High (user safety) | Define & measure recall target (Open Q #3); confirm real model deployed (Open Q #10) |
| Per-pixel YUV→RGB on UI thread may drop frames on low-end devices | Med (latency) | Define perf target + device tier (Open Q #11); consider isolate/native conversion |
| Integrity check disabled (placeholder hash) | Med (tampered model shipped silently) | Populate real SHA-256 in build (T-prefixed task) |
| No tests | Med (regressions) | Add unit tests for classifier/feedback logic |
| Liability of guiding blind users across roads | High (legal) | Disclaimer/safety-scope decision (Open Q #9) |

## Open Questions (require human decision — not guessed)
| # | Question | Status |
|---|---|---|
| 1 | Target platform(s): Android only, or iOS too? (CI=APK only; BGRA path hints iOS) | open |
| 2 | Minimum supported OS versions (Android minSdk / iOS target)? | open |
| 3 | Required accuracy — acceptable false-negative (missed-deviation) rate / recall target for left/right? | open |
| 4 | Confirm fully offline; any online component ever intended? | open |
| 5 | Accessibility standard to meet (WCAG level? native TalkBack/VoiceOver compatibility required)? | open |
| 6 | Supported languages — Korean only or multilingual? | open |
| 7 | Distribution & monetization (Play Store? free? app branding/identity)? | open |
| 8 | Intended phone posture/mounting (handheld, chest-mount, lanyard)? Needs user guidance? | open |
| 9 | Legal safety disclaimer / scope-of-use statement required in-app? | open |
| 10 | Is the committed `crosswalk_model.onnx` the real trained model or a dummy? (asset hash = placeholder) | open |
| 11 | Performance targets: min FPS, alert latency, battery budget, minimum device tier? | open |
| 12 | Behavior under low-light/night/rain/occlusion — in scope for v1? | open |
| 13 | Provide periodic positive "on-track" reassurance, or stay silent on front? | open |
| 14 | Camera choice — rear assumed; any front-camera or dual use case? | open |
