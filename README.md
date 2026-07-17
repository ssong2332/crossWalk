# crosswalk_app — 횡단보도 이탈 감지 (Crosswalk Deviation Detection)

On-device (offline) mobile app that warns a visually impaired user in real time, via voice + vibration, when they drift left/right off a crosswalk while crossing.
Source: `docs/PRD.md` Goal (evidence: `crosswalk_app/pubspec.yaml:2`, `crosswalk_app/lib/services/feedback_service.dart:30-38`).

## Status

Early-stage / not release-ready.

| Item | State | Detail |
|---|---|---|
| Core detection pipeline | Implemented | Camera stream → ONNX inference → smoothing → threshold → TTS/vibration alert (`docs/PRD.md` Features #1-9) |
| Open product decisions | 14 unresolved | See `docs/PRD.md` "Open Questions" (platform, min OS, accuracy target, offline confirmation, accessibility standard, language, distribution, phone mounting, legal disclaimer, model provenance, performance targets, low-light scope, reassurance feedback, camera choice) |
| Logits-vs-probability threshold defect (T21) | Fixed (unit-test level) | Model graph has no Softmax node (raw logits) but was compared against probability-scale thresholds 0.55/0.85 — fixed by adding a numerically-stable softmax before thresholding (`crosswalk_app/lib/services/classifier.dart:188-194`, commit `33786d7`). Verified only by unit tests (see `docs/Tasks.md` T9); real-camera/field detection-rate re-validation is still open (`docs/Tasks.md` T1, T12) |
| Camera re-init re-entrancy (T23) | Fixed | `_initCamera()` could run concurrently via rapid resume/retry, racing two `CameraController`/ONNX sessions. Fixed with an `_isInitializing` guard (`crosswalk_app/lib/screens/camera_screen.dart:54-55,135-137`, commit `a9b77f4`) |
| Native ONNX session/env leak (T24) | Fixed | `Classifier.init()` leaked `OrtSession`/`OrtEnv` on every re-init. Now releases the prior session first and inits the env only once per instance (`crosswalk_app/lib/services/classifier.dart:44-53,221-226`, commit `bc0bba8`) |
| Stale TTS alert (T25) | Fixed | `FeedbackService.alert()` now stops any in-progress speech before speaking a new alert, preventing a stale left/right cue on iOS (`AVSpeechSynthesizer` queues by default) (`crosswalk_app/lib/services/feedback_service.dart:42-43`, commit `e5ca05f`) |
| Model integrity check | Disabled | Bundled hash file is a placeholder; verification is skipped (`docs/PRD.md` Feature #12) — unchanged this session |
| Automated tests | 14 tests, CI-verified | 7 `Classifier` tests (`crosswalk_app/test/classifier_test.dart`, T9, commit `eb688a7`) + 7 `FeedbackService` tests (`crosswalk_app/test/feedback_service_test.dart`, T10, commits `cf81a77`/`d61bfa6`). **CI is the only place any test in this repo has actually run** — local `flutter_tester.exe` is broken on the dev machine, so "tests pass" claims before a CI run are unverified (`docs/Tasks.md` T10 note; latest passing run: GitHub Actions run 29474000817, 14/14) |

## Tech Stack

Flutter (Dart, SDK `>=3.0.0 <4.0.0`, per `crosswalk_app/pubspec.yaml:7-8`), plain `StatefulWidget`/`setState` (no state-management package).

| Package | Version | Purpose |
|---|---|---|
| `camera` | ^0.11.0+2 | Rear-camera frame stream |
| `onnxruntime` | ^1.4.0 | On-device 3-class inference |
| `image` | ^4.1.7 | YUV420/BGRA → RGB decode/resize |
| `flutter_tts` | ^4.0.2 | Spoken ko-KR alerts |
| `vibration` | ^2.0.0 | Haptic deviation alert |
| `permission_handler` | ^11.3.0 | Runtime camera permission |
| `wakelock_plus` | ^1.2.5 | Keep screen on while running |
| `crypto` | ^3.0.3 | Model SHA-256 integrity check (currently disabled) |

Full rationale table: `docs/Architecture.md` section 2.

## Repository Structure

| Path | Contents |
|---|---|
| `crosswalk_app/` | The real Flutter app (shipped artifact) |
| `crosswalk_app_scaffold/` | Unused default Flutter counter-app boilerplate — not part of the product, do not treat as source of truth (`docs/PRD.md` "Out of Scope") |
| `train/` | Offline model training pipeline (PyTorch, MobileNetV3-Small, ONNX export) — developer-run, not shipped in the app |
| `model/` | Trained model artifacts (`.pt`, `.onnx`, confusion matrix) |
| `image/` | Raw training images (front/left/right classes) |
| `docs/` | Project documentation (see below) |
| `.github/workflows/build_apk.yml` | CI: Android APK build (+ optional signing) |
| `ARCHITECTURE.md` (root) | Stale legacy doc — do not trust; superseded by `docs/Architecture.md` (drift tracked in `docs/Tasks.md` T14) |

## Build & Run

Verified against `.github/workflows/build_apk.yml` (CI) and `crosswalk_app/pubspec.yaml`.

Prerequisites:
- Flutter 3.32.2, stable channel (CI-verified version, `.github/workflows/build_apk.yml:32`)
- Dart SDK `>=3.0.0 <4.0.0` (`crosswalk_app/pubspec.yaml:7-8`)
- Java 17 (Temurin) for Android builds (`.github/workflows/build_apk.yml:23-27`)

Commands (run from `crosswalk_app/`):
```
flutter pub get
flutter run                    # local debug run
flutter build apk --release    # matches CI build step, .github/workflows/build_apk.yml:56-58
```

Notes:
- CI only builds an Android APK; iOS is not built/signed in CI. Whether iOS is an intended target is unresolved — see `docs/PRD.md` Open Question #1.
- Minimum Android SDK (minSdk) version is not documented anywhere in this repo — unresolved, see `docs/PRD.md` Open Question #2.
- The bundled ONNX model's integrity hash is a placeholder in this repo; a real model/hash is written only in CI or must be provided locally (`.github/workflows/build_apk.yml:36-50`).
- APK signing requires the `KEYSTORE_BASE64`/`KEY_ALIAS`/`KEY_PASSWORD`/`STORE_PASSWORD` secrets; without them CI produces an unsigned APK (`.github/workflows/build_apk.yml:60-91`).
- **Local `flutter build apk --release` and `flutter run --release` both fail by design without an opt-in.** `crosswalk_app/android/app/build.gradle.kts`'s `release` build type (lines 33-55) only debug-signs when `GITHUB_ACTIONS=true` (CI) or `project.hasProperty("allowDebugSigningForRelease")` is true; otherwise it throws a `GradleException` refusing to build, so a bare local release build/run is never silently debug-signed.
  - For `flutter build apk --release`, pass the opt-in directly on the command line: `flutter build apk --release -PallowDebugSigningForRelease=true`.
  - `flutter run --release` goes through the same Gradle `release` build type (`build.gradle.kts:33-55`) but Flutter's `flutter run` CLI has no documented way to forward arbitrary `-P` Gradle project properties, so it will also fail locally with the same `GradleException` and there is no equivalent one-off command-line flag.
  - To use `flutter run --release` locally for your own testing, add `allowDebugSigningForRelease=true` to your **personal, per-machine** Gradle properties file — `%USERPROFILE%\.gradle\gradle.properties` on Windows (`~/.gradle/gradle.properties` elsewhere), i.e. `GRADLE_USER_HOME`, **not** the project's own `crosswalk_app/android/gradle.properties` (that file is committed/shared by everyone who clones this repo). Gradle merges the user-home `gradle.properties` into every build on that machine and gives it precedence over the project's own `gradle.properties` (verified: Gradle docs, "Build environment", https://docs.gradle.org/current/userguide/build_environment.html — properties in `GRADLE_USER_HOME/gradle.properties` are read for every project on the machine and take precedence over the project-level file).
  - **Warning:** setting this in your personal `~/.gradle/gradle.properties` makes *every* Gradle `release`-type build on that machine debug-signed by default (not just this project), so never rely on a build produced this way for actual distribution — only use it for local `flutter run --release` testing.

## Documentation Index

| Doc | Purpose |
|---|---|
| `docs/PRD.md` | Goals, target users, feature status table, risks, 14 open product questions |
| `docs/Architecture.md` | As-built module breakdown, data flow, threading model, CI pipeline (authoritative — supersedes root `ARCHITECTURE.md`) |
| `docs/API.md` | Confirms no network API exists; documents internal ONNX tensor contract and service method contracts |
| `docs/Database.md` | Confirms no database/persistent storage exists; documents in-memory-only state |
| `docs/Tasks.md` | Follow-up task list (decision-blocked, correctness, performance, doc-sync, deferred features) |
| `docs/CodingRules.md` | Coding rules/prohibitions — template only, not yet filled in (`docs/CodingRules.md:1-8`) |
| `docs/DECISIONS.md` | Append-only decision log — template only, no entries yet (`docs/DECISIONS.md:1-6`) |
| `docs/DefinitionOfDone.md` | Checklist gating `docs/Tasks.md` status → `done` — template only (`docs/DefinitionOfDone.md:1-7`) |
| `docs/GitWorkflow.md` | Git branching/commit rules — template only, not yet filled in (`docs/GitWorkflow.md:1-6`) |
| `docs/PromptRules.md` | How to invoke the six agents + approval-gated pipeline (planner → architect → ...) (`docs/PromptRules.md:1-6`) |
| `docs/CHANGELOG.md` | Keep a Changelog-format log — `[Unreleased]` now populated with this session's changes (T9/T10/T21/T23/T24/T25); no tagged release yet |
| `docs/adr/` | Architecture Decision Records — currently only `0000-template.md`, no real ADRs written yet |
| `AGENTS.md` | Agent contract: pipeline, authority, document ownership, priority order |

## Known Limitations / Open Questions

See `docs/PRD.md` "Open Questions" (14 items) and "Risks" for the full list — not duplicated here. Highlights: no measured accuracy/recall target (still open, `docs/Tasks.md` T1/T12), model integrity check disabled, inference runs synchronously on the UI isolate (possible frame drops). The logits-vs-probability threshold defect (`docs/Tasks.md` T21) and the T23/T24/T25 camera-reinit/memory-leak/stale-TTS bugs are fixed this session (see Status table above) but field/real-camera accuracy validation remains open.
