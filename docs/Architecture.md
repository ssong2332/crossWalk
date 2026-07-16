# Architecture — crosswalk_app (횡단보도 이탈 감지)

Owner: architect (see AGENTS.md). Others read-only.
Last updated: 2026-07-16. Basis: direct inspection of `crosswalk_app/lib/**`, `crosswalk_app/pubspec.yaml`, `.github/workflows/build_apk.yml`, `train/train_model.py`. Every claim is cited to `file:line` or command output.
Requirements source: `docs/PRD.md`. Unresolved product decisions are NOT re-decided here — they are cross-referenced to `docs/PRD.md` Open Questions (Q#…).

> This document describes the system **as-built**. Where the root `ARCHITECTURE.md` disagrees with code, code wins (drift list in `docs/PRD.md` §"Known Documentation Drift"). Do not treat root `ARCHITECTURE.md` as authoritative.

## Prohibitions (for readers acting on this doc)
- Do not add a backend, network client, or database — none exists and none is in PRD scope (evidence below). Any such addition needs a PRD/Open-Question decision first.
- Do not "fix" the values in root `ARCHITECTURE.md` by trusting it; verify against code.

---

## 1. System Type — verified facts

| Property | Value | Evidence |
|---|---|---|
| App type | Single-screen Flutter mobile app | `main.dart:20` (only `CameraScreen` as `home`) |
| Backend / server | None | grep `http\|dio\|firebase\|supabase\|websocket\|Uri.` in `lib/` → 0 real matches (only `enableAudio: false` at `camera_screen.dart:98`) |
| Network I/O | None (fully offline / on-device) | same grep as above; PRD Goal line 9, Q#4 |
| Persistent storage / DB | None | grep `sqlite\|hive\|shared_preferences\|drift\|isar\|path_provider\|writeAsString` in `lib/` → 0 matches |
| Inference | On-device ONNX Runtime | `classifier.dart:5,42,79` |
| Model asset | Bundled in APK | `pubspec.yaml:30` (`assets/model/`), `classifier.dart:39` |
| Confirmed platform | Android (CI builds APK only) | `build_apk.yml:58`; iOS unconfirmed → Q#1 |

Offline claim is **confirmed by code** (no network surface). "Intended to stay offline forever" is a product decision → PRD Q#4.

---

## 2. Tech Stack

| Layer | Choice | Reason (evidence) |
|---|---|---|
| UI framework | Flutter (Dart, SDK `>=3.0.0 <4.0.0`) | `pubspec.yaml:7-8` |
| State management | Plain `StatefulWidget` + `setState` | `camera_screen.dart:16,53,140`; no state-mgmt package in `pubspec.yaml:10-20` |
| Camera | `camera ^0.11.0+2` | `pubspec.yaml:13`; used `camera_screen.dart:3,95-107` |
| ML inference | `onnxruntime ^1.4.0` | `pubspec.yaml:14`; `classifier.dart:5,42,79` |
| Image preprocessing | `image ^4.1.7` | `pubspec.yaml:17`; `classifier.dart:6,120-175` |
| Voice feedback | `flutter_tts ^4.0.2` (ko-KR) | `pubspec.yaml:15`; `feedback_service.dart:1,12,34` |
| Haptic feedback | `vibration ^2.0.0` | `pubspec.yaml:16`; `feedback_service.dart:2,36-38` |
| Permissions | `permission_handler ^11.3.0` | `pubspec.yaml:18`; `camera_screen.dart:4,62` |
| Screen-on | `wakelock_plus ^1.2.5` | `pubspec.yaml:19`; `camera_screen.dart:5,48,163` |
| Integrity hash | `crypto ^3.0.3` (SHA-256) | `pubspec.yaml:20`; `classifier.dart:3,55` |
| Lint | `flutter_lints ^3.0.0` | `pubspec.yaml:25` |
| Model training (offline, not shipped) | PyTorch + torchvision MobileNetV3-Small | `train/train_model.py:10,106` |

### Dependency rationale (why each is present)
| Package | Justified by requirement | Removable without feature loss? |
|---|---|---|
| camera | Live rear-camera frame stream (PRD F1) | No |
| onnxruntime | Core 3-class inference (PRD F2) | No |
| image | YUV420/BGRA → RGB decode + resize (PRD F3) | No |
| flutter_tts | Spoken ko-KR alerts (PRD F7) | No |
| vibration | Haptic deviation alert (PRD F7) | No |
| permission_handler | Runtime camera permission (PRD F10) | No |
| wakelock_plus | Keep screen on during crossing (PRD F11) | No |
| crypto | Model integrity SHA-256 (PRD F12, currently disabled) | Yes, but drops tamper check |

---

## 3. Folder Structure (as-built)

```
crossWalk/
├── crosswalk_app/                 # Flutter app — SHIPPED artifact
│   ├── lib/
│   │   ├── main.dart              # entrypoint: portrait lock, dark theme, home=CameraScreen
│   │   ├── screens/
│   │   │   └── camera_screen.dart # UI + lifecycle + orchestration
│   │   └── services/
│   │       ├── classifier.dart    # preprocessing + ONNX inference + smoothing/threshold
│   │       └── feedback_service.dart # TTS + vibration + cooldown
│   ├── assets/model/
│   │   ├── crosswalk_model.onnx
│   │   └── crosswalk_model.onnx.sha256   # = "placeholder_hash" (check disabled)
│   └── pubspec.yaml
├── train/                         # OFFLINE model pipeline — NOT in app
│   ├── train_model.py             # train + evaluate + ONNX export
│   ├── convert_to_tflite.py       # unused (TFLite path abandoned)
│   ├── requirements.txt
│   └── data_prepared/             # split dataset (train/val/test)
├── model/                         # training artifacts (.pt/.onnx/confusion_matrix.png)
├── image/                         # raw training images (front/left/right)
├── crosswalk_app_scaffold/        # UNUSED default Flutter boilerplate (ignore) — PRD "Out of Scope"
├── .github/workflows/build_apk.yml
└── ARCHITECTURE.md                # STALE root doc — do not trust (PRD drift list)
```
Evidence: file layout confirmed by glob of `crosswalk_app/lib/**`, `train/**`; `crosswalk_app_scaffold` flagged unused in `docs/PRD.md:62`.

---

## 4. Component / Module Breakdown

| Component | File | Responsibility | Must NOT do |
|---|---|---|---|
| `main()` / `CrosswalkApp` | `main.dart:5-23` | Portrait lock (`main.dart:7`), dark theme, mount `CameraScreen` | Business logic |
| `CameraScreen` (StatefulWidget) | `camera_screen.dart:9-288` | Orchestrate init sequence, own `CameraController`, handle lifecycle & wakelock, render overlay UI, route frames to services | Preprocess/infer directly (delegates to `Classifier`) |
| `Classifier` (service) | `classifier.dart:21-181` | Load+verify model, throttle, preprocess frame, run ONNX, smooth probs, apply thresholds, return `ClassificationResult?` | Touch UI / TTS / vibration |
| `FeedbackService` (service) | `feedback_service.dart:4-50` | TTS + vibration, per-class cooldown, spoken error announcements | Touch camera / inference |
| `ClassificationResult` (DTO) | `classifier.dart:8-12` | Immutable `{label, confidence}` | — |
| `ModelIntegrityException` | `classifier.dart:14-19` | Signal corrupt/tampered model → surfaced as error UI (`camera_screen.dart:109`) | — |

Boundary rule (as-built, keep it): UI (`screens/`) depends on services (`services/`); services have **no** Flutter-widget dependency. `Classifier` and `FeedbackService` do not reference each other — both are coordinated by `CameraScreen`.

---

## 5. Data Flow

```mermaid
flowchart TD
  CAM[CameraController image stream<br/>YUV420, medium res, portrait-locked, audio off] -->|CameraImage| ONF[CameraScreen._onFrame]
  ONF -->|_isProcessing guard| CLS[Classifier.processFrame]
  CLS -->|frameCount %% 5 != 0| SKIP[return null — throttled]
  CLS -->|every 5th frame| PRE[_preprocessCamera<br/>YUV420/BGRA -> RGB -> 224x224<br/>NCHW + ImageNet norm]
  PRE --> ORT[OrtSession.run input:1x3x224x224]
  ORT --> OUT[output vector, 3 values]
  OUT --> SMOOTH[append to last-5 window, average]
  SMOOTH --> ARGMAX[argmax -> label]
  ARGMAX --> TH{conf >= threshold?<br/>front 0.85 / left,right 0.55}
  TH -->|no| NULL[return null]
  TH -->|yes| RES[ClassificationResult label, confidence]
  RES --> UI[setState: color+icon+text+conf%]
  RES --> FB[FeedbackService.alert]
  FB -->|front| SILENT[no output]
  FB -->|left/right, cooldown ok| TTS[TTS ko-KR + vibrate 500ms]
```

Step-by-step with evidence:
| # | Step | Evidence |
|---|---|---|
| 1 | Frame stream starts (YUV420, `ResolutionPreset.medium`, `enableAudio:false`, orientation locked) | `camera_screen.dart:95-107` |
| 2 | `_onFrame` re-entrancy guard via `_isProcessing` | `camera_screen.dart:132-134,147` |
| 3 | Throttle: infer only every 5th frame | `classifier.dart:31,68-69` |
| 4 | Preprocess: format branch YUV420 vs BGRA, resize 224², NCHW + ImageNet mean/std | `classifier.dart:113-146` |
| 5 | YUV420→RGB per-pixel BT.601 conversion | `classifier.dart:152-175` |
| 6 | Inference: `OrtSession.run(..., {'input': tensor})`, read `outputs.first` | `classifier.dart:74-88` |
| 7 | Smoothing: keep last 5 prob vectors, average | `classifier.dart:24,90-98` |
| 8 | Decision: argmax + asymmetric threshold (front 0.85 / deviation 0.55) | `classifier.dart:27-28,100-108` |
| 9 | UI update via `setState` (label text + confidence %) | `camera_screen.dart:139-144,231-258` |
| 10 | Feedback: front silent; left/right → TTS + 500ms vibrate with 3s per-class cooldown | `feedback_service.dart:17-38` |

---

## 6. Threading / Concurrency Model (flagged concern)

| Aspect | As-built | Evidence | Concern |
|---|---|---|---|
| Inference isolate | **None** — runs on the frame-stream callback (main isolate) | `classifier.dart:67-111` is fully synchronous; called directly in `camera_screen.dart:136` | Heavy per-pixel YUV→RGB Dart loop + ONNX run on UI isolate can drop/stall frames on low-end devices |
| YUV→RGB conversion | Synchronous nested `for` over every pixel | `classifier.dart:162-173` | O(width×height) on UI isolate per inferred frame |
| Re-entrancy control | Boolean flag `_isProcessing`, not a queue | `camera_screen.dart:133-134,147` | Because `processFrame` is synchronous, the flag is set/cleared within one synchronous call — it drops overlapping native callbacks rather than parallelizing |
| `compute`/`Isolate` usage | None | grep `Isolate\|compute(` in `lib/` → 0 matches | Moving work off UI isolate is deferred: `docs/Tasks.md` T13 |

Performance targets (FPS/latency/battery/min device) are **undefined** → PRD Q#11; do not optimize blindly without a target (Tasks T12→T13).

---

## 7. State Management

| Question | Answer | Evidence |
|---|---|---|
| Pattern | Local widget state via `setState` in one `StatefulWidget` | `camera_screen.dart:16,53-56,108,140-144` |
| State fields | `_statusLabel`, `_confidence`, `_isProcessing`, `_hasError` | `camera_screen.dart:21-24` |
| Global store (Provider/Bloc/Riverpod/GetX) | None | absent from `pubspec.yaml:10-20` |
| Service state | `Classifier` holds `_session`, `_frameCount`, `_recentProbs`; `FeedbackService` holds cooldown timestamps | `classifier.dart:33-35`, `feedback_service.dart:6-9` |

Adequate for a single-screen app. Adding screens (onboarding/settings, PRD F16 / Tasks T19) may warrant revisiting — not required now.

---

## 8. Initialization & Lifecycle (as-built — differs from root doc)

Actual `_initCamera` order (root `ARCHITECTURE.md` is wrong here — PRD drift note):
```
FeedbackService.init (TTS first, so later errors can be spoken)  camera_screen.dart:60
  -> Permission.camera.request                                   camera_screen.dart:62-72
  -> Classifier.init (load + verify + OrtSession)                camera_screen.dart:74-75
  -> availableCameras / pick back camera                         camera_screen.dart:78-93
  -> CameraController.initialize + lockCaptureOrientation        camera_screen.dart:95-103
  -> startImageStream(_onFrame)                                  camera_screen.dart:107
```
Lifecycle: background (`inactive`) → dispose controller (`camera_screen.dart:153-154`); `resumed` → re-run `_initCamera` (`camera_screen.dart:155-156`). Wakelock enabled in `initState` (`:48`), disabled in `dispose` (`:163`).

Error handling → red overlay + spoken message + "다시 시도" retry button:
| Failure | Message | Evidence |
|---|---|---|
| Permission denied | "카메라 권한이 필요합니다…" | `camera_screen.dart:62-72` |
| No camera | "카메라를 찾을 수 없습니다." | `camera_screen.dart:79-88` |
| Model corrupt (`ModelIntegrityException`) | "모델 파일이 손상되었습니다…" | `camera_screen.dart:109-118` |
| Generic | "앱 오류로 감지를 시작할 수 없습니다…" | `camera_screen.dart:119-129` |
| Retry | `_initCamera` re-invoked | `camera_screen.dart:265` |

---

## 9. Model Integrity (as-built: DISABLED)

| Fact | Evidence |
|---|---|
| SHA-256 verify logic exists | `classifier.dart:45-65` |
| Verification skipped when hash is `placeholder_hash` or not 64-hex | `classifier.dart:53` |
| Shipped hash IS the placeholder | `assets/model/crosswalk_model.onnx.sha256:1` = `placeholder_hash` |
| CI writes real hash only if a real model is present; else writes `placeholder`/`placeholder_hash` | `build_apk.yml:41-50` |

Net effect: integrity check is **off** in current builds. Fix tracked as `docs/Tasks.md` T7; whether the committed model is real vs dummy is PRD Q#10 / Tasks T8.

---

## 10. Build & Deploy Pipeline (CI)

| Stage | Detail | Evidence |
|---|---|---|
| Trigger | push to `develop`; PR to `master` | `build_apk.yml:3-9` |
| Runner | `ubuntu-latest` | `build_apk.yml:14` |
| Toolchain | Java 17 (Temurin), Flutter 3.32.2 stable (cached) | `build_apk.yml:23-34` |
| Model gate | If model missing/`placeholder` → write dummy + placeholder hash (marked "배포 불가"); else compute real SHA-256 into `.sha256` | `build_apk.yml:36-50` |
| Install | `flutter pub get` (cwd `crosswalk_app`) | `build_apk.yml:52-54` |
| Build | `flutter build apk --release` | `build_apk.yml:56-58` |
| Sign | zipalign + apksigner only if `KEYSTORE_BASE64` secret set; else unsigned "배포 불가" | `build_apk.yml:60-91` |
| Publish | `upload-artifact` (signed + unsigned), 30-day retention | `build_apk.yml:93-101` |
| Supply-chain | `actions/checkout` pinned to SHA; other actions `TODO: SHA 고정` | `build_apk.yml:17-21,25,31,94` |

Drift note: root `ARCHITECTURE.md` says the build uses `--no-shrink`; actual CI command is `flutter build apk --release` with no such flag (`build_apk.yml:58`). Trust code. (`CLAUDE.md` "Verified Commands" table is still placeholder → Tasks T15.)

---

## 11. Offline Model-Training Pipeline (relation to shipped asset)

Separate, offline, developer-run; not part of the APK runtime.

| Item | Detail | Evidence |
|---|---|---|
| Base model | MobileNetV3-Small (ImageNet weights), final layer → 3 classes | `train_model.py:106-109` |
| Classes / order | `["front","left","right"]` | `train_model.py:30` |
| Preprocessing (train) | Resize 224², ImageNet mean/std — matches app | `train_model.py:74-85` vs `classifier.dart:133-134` |
| Class-imbalance handling | front capped 500, WeightedRandomSampler, loss weights front=1/left=10/right=20 | `train_model.py:23,91-94,146` |
| ONNX export | `torch.onnx.export`, `input_names=["input"]`, `output_names=["output"]`, `opset_version=17`, dynamic batch | `train_model.py:221-227` |
| Runtime tensor contract match | app feeds `'input'`, reads `outputs.first` | `classifier.dart:79,85-87` |

Consistency check: tensor names and normalization match between training and app. Two unresolved gaps below.

---

## 12. Authentication / Authorization

N/A. No user accounts, no network, no protected resource. Only OS runtime permission used is camera (`camera_screen.dart:62`).

---

## 13. Conventions (rules implementer must keep)

- Services (`services/*.dart`) stay framework-light: no `material.dart` / widget imports. Current: `classifier.dart` and `feedback_service.dart` import only dart/plugin libs (`classifier.dart:1-6`, `feedback_service.dart:1-2`). Keep it.
- UI orchestrates; services do one job each (see §4). Do not let `Classifier` speak/vibrate or `FeedbackService` infer.
- Class label order is fixed `['front','left','right']` and must match the ONNX output order (`classifier.dart:22`, `train_model.py:30`). Do not reorder on one side only.
- Any threshold/throttle/smoothing change must be reflected in docs AND (per PRD) not contradict a safety target once Q#3 is answered.

---

## 14. Risks & Trade-offs

| Decision (as-built) | Trade-off / risk | Pointer |
|---|---|---|
| Inference on UI isolate | Simpler code; risk of frame drops on low-end devices | Tasks T12/T13; PRD Q#11 |
| Integrity check disabled (placeholder hash) | Ships without tamper detection | Tasks T7; PRD Q#10 |
| Asymmetric thresholds (0.85/0.55) favor catching deviations | More false alarms accepted to reduce missed deviations; no measured recall | PRD Q#3, Risks table |
| Single-screen `setState` | Fast to build; limited if onboarding/settings added | PRD F16; Tasks T19 |
| No automated tests | Regression risk in classifier/feedback logic | Tasks T9–T11 |
| Model output treated as probabilities without confirmed softmax | Thresholds may be meaningless if ONNX emits raw logits | Open Question A below |

---

## 15. New Open Questions (raised by architecture review — route to planner/PRD)

These are NOT decided here. They extend `docs/PRD.md` Open Questions.

| ID | Question | Why it matters | Related PRD Q |
|---|---|---|---|
| A | Does the shipped `crosswalk_model.onnx` include a final softmax? `train_model.py` `build_model` has **no** softmax (`:105-109`) and trains with `CrossEntropyLoss` on logits (`:151`), yet the app compares outputs to probability thresholds 0.55/0.85 (`classifier.dart:107-108`). If the ONNX emits logits, thresholds are ill-defined. Cannot be confirmed from Dart/py alone — inspect the ONNX graph. | Directly affects detection correctness/safety | Q#3, Q#10 |
| B | Shipped ONNX was exported with which opset/IR? `train_model.py` uses opset 17 (`:226`); git log shows "ONNX IR version 다운그레이드 (10→7)"; PRD notes an `export_onnx.py` (opset 12) referenced by root doc but absent. The exact export path of the bundled model is untracked. | Runtime compat + reproducibility | Q#10 |
| C | Is BGRA preprocessing path (`classifier.dart:119-125`) dead code on Android-only builds, or a committed intent to support iOS? | Scope of platform support | Q#1 |

See `docs/PRD.md` §"Open Questions" for the full unresolved-decisions list; not duplicated here.
