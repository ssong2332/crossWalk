# Changelog

Owner: docs agent (see AGENTS.md). Format: [Keep a Changelog](https://keepachangelog.com/), newest first.

## [Unreleased]
### Added
- 7 unit tests for `Classifier` covering softmax correctness/numerical stability, threshold reachability (0.55/0.85), smoothing window, threshold gating, and frame throttle — `crosswalk_app/test/classifier_test.dart` (`docs/Tasks.md` T9, commit `eb688a7`).
- 7 unit tests for `FeedbackService` covering front-silence, first-alert, cooldown suppression/boundary expiry, class-change bypass, and exact left/right message text — `crosswalk_app/test/feedback_service_test.dart` (`docs/Tasks.md` T10, commits `cf81a77`, `d61bfa6`).
- CI "Flutter 테스트" step (`flutter test`) added to `.github/workflows/build_apk.yml:56-58`, run before the APK build, since local `flutter_tester.exe` is broken on the dev machine (commit `84f1c69`).

### Changed
- Extracted `Classifier.softmax` / `decideFromLogits` / `shouldProcessFrame` as `@visibleForTesting` methods via a behavior-preserving refactor to enable unit testing (`crosswalk_app/lib/services/classifier.dart:110-194`, `docs/Tasks.md` T9, commit `eb688a7`).
- Extracted `FeedbackService.decideMessage` as a `@visibleForTesting` pure function with time injected as a parameter, for deterministic testing (`crosswalk_app/lib/services/feedback_service.dart:20-36`, `docs/Tasks.md` T10, commit `cf81a77`).

### Fixed
- **T21 (P0, safety)**: bundled ONNX model outputs raw logits (no Softmax node) but `classifier.dart` compared them against probability-scale thresholds (0.55/0.85), risking the crosswalk-deviation alert silently misfiring or never firing. Fixed by applying a numerically-stable softmax to the raw logits before thresholding — `crosswalk_app/lib/services/classifier.dart:188-194` (commit `33786d7`). Verified at unit-test level only (T9); field/real-camera detection-rate re-validation remains open (`docs/Tasks.md` T1/T12).
- **T23 (P0, concurrency)**: `_initCamera()` had no re-entrancy guard, allowing concurrent `CameraController`/ONNX session creation via rapid resume/retry (from `didChangeAppLifecycleState` or the retry button). Fixed with an `_isInitializing` guard wrapping the whole body in try/finally, and the retry button is now disabled while a call is in flight — `crosswalk_app/lib/screens/camera_screen.dart:54-55,135-137,273` (commit `a9b77f4`).
- **T24 (P1, memory leak)**: `Classifier.init()` unconditionally created a new `OrtSession` without releasing the previous one, and re-initialized the non-idempotent native `OrtEnv` on every call. Fixed by releasing the prior session before reassigning and gating `OrtEnv.instance.init()` to once per instance — `crosswalk_app/lib/services/classifier.dart:44-53,221-226` (commit `bc0bba8`).
- **T25 (P1, stale safety cue)**: `FeedbackService.alert()` did not stop prior in-progress TTS speech before speaking a new alert. Load-bearing on iOS, where `AVSpeechSynthesizer` queues utterances by default (Android's `flutter_tts` 4.2.5 already defaults to `QUEUE_FLUSH`). Fixed with `await _tts.stop()` before `speak()` — `crosswalk_app/lib/services/feedback_service.dart:42-43` (commit `e5ca05f`).

## [0.1.0] - {{YYYY-MM-DD}}
### Added
- Initial release.
