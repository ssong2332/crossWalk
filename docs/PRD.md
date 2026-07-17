# PRD — crosswalk_app (횡단보도 이탈 감지)

Owner: planner (see AGENTS.md). Others read-only.
Last updated: 2026-07-16. Basis: code inspection of `crosswalk_app/lib/`, `crosswalk_app/pubspec.yaml`, `.github/workflows/build_apk.yml`, `train/`, `model/`, and git history (`develop`).

> Status legend: 구현됨 = implemented (evidence in code), 부분구현 = partial, 미구현 = not implemented, 추정 = inferred (not confirmable from code — see Open Questions).

## Goal
On-device (offline, 추정) mobile app that warns a visually impaired user in real time, via voice + vibration, when they drift left/right off a crosswalk while crossing.
Evidence: `pubspec.yaml:2` (description), `ARCHITECTURE.md:3`, `crosswalk_app/lib/services/feedback_service.dart:30-38`.

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
| Safety (false-negative risk) | Training weights left=10/right=20 vs front=1 (`ARCHITECTURE.md:77`); deviation threshold lowered to 0.55 | Deviation recall ≥ 90% / miss rate ≤ 10% (Open Q #3, ANSWERED 2026-07-17). Front false-positive tolerance not yet defined. |
| Model provenance | App-bundled `crosswalk_model.onnx` present; integrity hash is placeholder → verification effectively off | Confirm real vs dummy model → Open Q #10 |

## Known Documentation Drift (evidence-based, not requirements)
`ARCHITECTURE.md` is stale vs current code — flag for docs agent, not a code change:
- Throttle: doc says 10 (`ARCHITECTURE.md:174,196`); code is 5 (`classifier.dart:31`).
- Threshold: doc says single 0.70 (`ARCHITECTURE.md:172,189`); code uses 0.85/0.55 (`classifier.dart:27-28`).
- Init order: doc says permission→model→TTS (`ARCHITECTURE.md:127-137`); code is TTS→permission→model (`camera_screen.dart:60-75`).
- `export_onnx.py` described (`ARCHITECTURE.md:90`) — **correction**: an earlier pass of this doc claimed it was "absent from `train/`"; that was wrong. `train/export_onnx.py` exists (25 lines) as a standalone re-export script separate from `train_model.py`'s embedded exporter; it is the script whose settings (opset 12, `dynamo=False`) match the currently-shipped model's verified `ir_version=7`/`opset=12`. Full trace: `docs/Architecture.md` §11.1/§11.2.

## Out of Scope (current build)
- iOS build/signing (CI produces APK only). NOTE: iOS is now an in-scope target platform (Open Q #1 ANSWERED 2026-07-17), but no iOS build/signing pipeline exists yet — building it is tracked as T33, not part of the current build.
- GPS/location, traffic-signal detection, obstacle detection.
- `crosswalk_app_scaffold/` — default Flutter counter-app boilerplate, unused (`crosswalk_app_scaffold/lib/main.dart:1-15`).

## Assumptions (推定 — verify before building on them)
- v1 runs offline on-device; online components may be added later (Open Q #4, ANSWERED 2026-07-17 — no longer a fixed fully-offline assumption).
- Rear camera only (Open Q #14, ANSWERED 2026-07-17), chest-mounted (lanyard/chest-mount) facing the crosswalk ahead (Open Q #8, ANSWERED 2026-07-17). Frame-interpretation/preprocessing may need re-review against this posture — see T35.
- Multilingual support required (Open Q #6, ANSWERED 2026-07-17) — the prior "Korean-only for v1" assumption is retired; current code hardcodes ko-KR (see T34).

## Risks
| Risk | Impact | Mitigation |
|---|---|---|
| False negative (miss a deviation) | High (user safety) | Recall target ≥ 90% / miss ≤ 10% set (Open Q #3, ANSWERED 2026-07-17) — now measure against it (T1); confirm real model deployed (Open Q #10, done) |
| Per-pixel YUV→RGB on UI thread may drop frames on low-end devices | Med (latency) | Define perf target + device tier (Open Q #11); consider isolate/native conversion |
| Integrity check disabled (placeholder hash) | Med (tampered model shipped silently) | Populate real SHA-256 in build (T-prefixed task) |
| No tests | Med (regressions) | Add unit tests for classifier/feedback logic |
| Liability of guiding blind users across roads | High (legal) | Disclaimer required at onboarding/first launch (Open Q #9, ANSWERED 2026-07-17) — implement via T36 |

## Open Questions (require human decision — not guessed)
| # | Question | Status |
|---|---|---|
| 1 | Target platform(s): Android only, or iOS too? (CI=APK only; BGRA path hints iOS) | ANSWERED (user, 2026-07-17): BOTH Android and iOS. NOTE: no iOS build/signing pipeline exists yet (CI is Android/APK-only) — see Out of Scope; new task candidate T33 (iOS build/signing pipeline). |
| 2 | Minimum supported OS versions (Android minSdk / iOS target)? | ANSWERED (user, 2026-07-17): Android minSdk 26 (Android 8.0); iOS minimum = iOS 15. Both parts now decided. NOTE: reflecting these values in the actual project config (Android Gradle minSdk, iOS deployment target in the Xcode/Runner project) is separate implementer work — Android config under T2; iOS config work is coupled to the iOS build/signing pipeline (T33), which is currently PAUSED (see T33). |
| 3 | Required accuracy — acceptable false-negative (missed-deviation) rate / recall target for left/right? | ANSWERED (user, 2026-07-17): deviation (left/right) detection target recall ≥ 90%, i.e. false-negative (missed-deviation) rate ≤ 10%. NOTE: acceptable front (normal) false-positive rate was NOT stated by the user — left undecided, not guessed. |
| 4 | Confirm fully offline; any online component ever intended? | ANSWERED (user, 2026-07-17): NOT confirmed as permanently fully offline. v1 is offline, but "추후 온라인 요소 추가 가능성 있음" (online components such as server communication / remote logging may be added in the future). So "fully offline" is not a fixed constraint. |
| 5 | Accessibility standard to meet (WCAG level? native TalkBack/VoiceOver compatibility required)? | open (user re-confirmed, 2026-07-17: 아직 미정 / still undecided). |
| 6 | Supported languages — Korean only or multilingual? | ANSWERED (user, 2026-07-17): multilingual required (not Korean-only). NOTE: `feedback_service.dart` currently hardcodes ko-KR — see new task candidate T34 (multi-language support). |
| 7 | Distribution & monetization (Play Store? free? app branding/identity)? | open (user re-confirmed, 2026-07-17: 아직 미정 / still undecided). |
| 8 | Intended phone posture/mounting (handheld, chest-mount, lanyard)? Needs user guidance? | ANSWERED (user, 2026-07-17): chest-mount (목걸이/가슴대, lanyard/chest-mount) assumed. NOTE: this camera angle differs from the prior "handheld facing ahead" assumption; frame-interpretation/preprocessing may need re-review for this posture — see new task candidate T35. |
| 9 | Legal safety disclaimer / scope-of-use statement required in-app? | ANSWERED (user, 2026-07-17): required — a disclaimer must be shown at onboarding / first launch. NOTE: no onboarding screen exists yet — see new task candidate T36 (onboarding + disclaimer). |
| 10 | Is the committed `crosswalk_model.onnx` the real trained model or a dummy? (asset hash = placeholder) | ANSWERED (user, 2026-07-17): genuinely the real trained-model output, NOT a dummy — independently verified byte-for-byte identical to `model/crosswalk_model.onnx` (the training pipeline's actual output file, `cmp` confirmed, 6,098,102 bytes). CAVEAT (user): training may not be complete/final — this could be an intermediate checkpoint rather than the final production-quality model. REASON (user, 2026-07-17): current training data is insufficient in volume/coverage; a retraining pass with more data is planned for later. This does NOT block enabling integrity verification (T7) or confirming asset provenance (T8), since both only require the committed file to genuinely be pipeline output (now confirmed) — but it DOES mean Open Question #3 (accuracy/recall target) cannot yet be validated against this specific model with confidence that it represents final quality, and any future model replacement (once retraining with more data completes) will require regenerating the SHA-256 hash (T7) and re-verifying the byte-match (T8) against the new final checkpoint. |
| 11 | Performance targets: min FPS, alert latency, battery budget, minimum device tier? | open (user re-confirmed, 2026-07-17: 아직 미정 — to be decided after on-device/real-device testing). |
| 12 | Behavior under low-light/night/rain/occlusion — in scope for v1? | ANSWERED (user, 2026-07-17): low-light/night IS in scope for v1, with improvement needed later. No low-light handling exists in code today — see new task candidate T37. (rain/occlusion not separately addressed by the user.) |
| 13 | Provide periodic positive "on-track" reassurance, or stay silent on front? | ANSWERED (user, 2026-07-17): stay silent on front (keep current behavior). No code change needed. |
| 14 | Camera choice — rear assumed; any front-camera or dual use case? | ANSWERED (user, 2026-07-17): rear camera only (keep current behavior). No code change needed. |
