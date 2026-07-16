# crosswalk_app — 횡단보도 이탈 감지 (Crosswalk Deviation Detection)

On-device (offline) mobile app that warns a visually impaired user in real time, via voice + vibration, when they drift left/right off a crosswalk while crossing.
Source: `docs/PRD.md` Goal (evidence: `crosswalk_app/pubspec.yaml:2`, `crosswalk_app/lib/services/feedback_service.dart:30-38`).

## Status

Early-stage / not release-ready.

| Item | State | Detail |
|---|---|---|
| Core detection pipeline | Implemented | Camera stream → ONNX inference → smoothing → threshold → TTS/vibration alert (`docs/PRD.md` Features #1-9) |
| Open product decisions | 14 unresolved | See `docs/PRD.md` "Open Questions" (platform, min OS, accuracy target, offline confirmation, accessibility standard, language, distribution, phone mounting, legal disclaimer, model provenance, performance targets, low-light scope, reassurance feedback, camera choice) |
| Known correctness concern under investigation | Open | Model output may be raw logits, not softmax probabilities, while the app compares them against probability thresholds (0.55/0.85) — see `docs/Tasks.md` T21 |
| Model integrity check | Disabled | Bundled hash file is a placeholder; verification is skipped (`docs/PRD.md` Feature #12) |
| Automated tests | None | No `crosswalk_app/test/` directory yet (`docs/PRD.md` Feature #19) |

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
| `docs/CHANGELOG.md` | Keep a Changelog-format log — template only, no released entries yet (`docs/CHANGELOG.md:1-6`) |
| `docs/adr/` | Architecture Decision Records — currently only `0000-template.md`, no real ADRs written yet |
| `AGENTS.md` | Agent contract: pipeline, authority, document ownership, priority order |

## Known Limitations / Open Questions

See `docs/PRD.md` "Open Questions" (14 items) and "Risks" for the full list — not duplicated here. Highlights: no measured accuracy/recall target, model integrity check disabled, no automated tests, inference runs synchronously on the UI isolate (possible frame drops), and the logits-vs-probability threshold concern tracked as `docs/Tasks.md` T21.
