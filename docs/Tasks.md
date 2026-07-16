# Tasks — crosswalk_app

Owner: planner (see AGENTS.md). Status values: `todo` / `in-progress` / `review` / `done`.
Derived from gaps found in code inspection (2026-07-16). Each row cites the motivating evidence.
Tasks marked ⛔BLOCKED depend on an Open Question in `docs/PRD.md` and must not start until answered.

## A. Blocked on decisions (resolve Open Questions first)
| ID | Task | Priority | Depends on | Acceptance Criteria | Status |
|---|---|---|---|---|---|
| T1 | Define & document model accuracy target (recall for left/right) | P0 | ⛔Open Q #3 | Numeric target recorded in PRD; measurable on test set | todo |
| T2 | Confirm target platforms & min OS; align CI accordingly | P0 | ⛔Open Q #1,#2 | Platforms/min OS stated; CI matches | todo |
| T3 | Decide accessibility standard & screen-reader requirement | P1 | ⛔Open Q #5 | Standard chosen; conformance checklist created | todo |
| T4 | Decide multi-language scope | P2 | ⛔Open Q #6 | Language list fixed | todo |
| T5 | Decide in-app safety disclaimer requirement | P1 | ⛔Open Q #9 | Yes/no + copy if yes | todo |
| T6 | Decide low-light/adverse-condition scope for v1 | P2 | ⛔Open Q #12 | In/out of scope recorded | todo |

## B. Ready — safety & correctness (no decision needed)
| ID | Task | Priority | Depends on | Acceptance Criteria | Status |
|---|---|---|---|---|---|
| T7 | Populate real SHA-256 for bundled model; enable integrity verification | P0 | Open Q #10 answered | `crosswalk_model.onnx.sha256` holds real 64-hex hash; app rejects tampered model. Evidence gap: `assets/model/crosswalk_model.onnx.sha256:1` = `placeholder_hash` | todo |
| T8 | Confirm committed `crosswalk_model.onnx` is the real trained model (not dummy) | P0 | Open Q #10 | Verified match with `model/crosswalk_model.onnx` | todo |
| T9 | Add unit tests for `Classifier` (smoothing, thresholds, throttle) | P1 | — | Tests exist under `crosswalk_app/test/` and pass. Gap: no test dir | todo |
| T10 | Add unit tests for `FeedbackService` (cooldown, class-change, front-silence) | P1 | — | Tests cover `feedback_service.dart:17-39` | todo |
| T11 | Add widget test for `CameraScreen` error/retry states | P2 | — | Covers `_hasError` overlay + retry (`camera_screen.dart:202-278`) | todo |

## C. Ready — performance
| ID | Task | Priority | Depends on | Acceptance Criteria | Status |
|---|---|---|---|---|---|
| T12 | Define performance targets (FPS, latency, battery, min device) | P1 | Open Q #11 | Targets in PRD | todo |
| T13 | Investigate moving YUV→RGB + inference off UI isolate | P2 | T12 | Measured frame-drop/latency improvement vs baseline. Gap: `_onFrame` runs sync on UI thread (`camera_screen.dart:132-148`) | todo |

## D. Documentation sync (docs agent)
| ID | Task | Priority | Depends on | Acceptance Criteria | Status |
|---|---|---|---|---|---|
| T14 | Fix `ARCHITECTURE.md` drift: throttle 10→5, threshold 0.70→0.85/0.55, init order, remove `export_onnx.py` | P1 | — | Doc matches code (see PRD "Documentation Drift") | todo |
| T15 | Fill `CLAUDE.md` project overview + verified build/test/run commands | P2 | — | Placeholders replaced with real values | todo |

## E. Deferred / decision-gated features
| ID | Task | Priority | Depends on | Acceptance Criteria | Status |
|---|---|---|---|---|---|
| T16 | Native Semantics / screen-reader compatibility | P2 | T3 | Meets chosen standard | todo |
| T17 | Multi-language TTS | P3 | T4 | Languages selectable/auto | todo |
| T18 | Optional periodic "on-track" reassurance feedback | P3 | Open Q #13 | Configurable behavior | todo |
| T19 | Onboarding / phone-posture guidance screen | P3 | Open Q #8,#14 | Guidance flow present | todo |
| T20 | Remove or repurpose unused `crosswalk_app_scaffold/` | P3 | — | Dir removed or documented. Evidence: default counter app (`crosswalk_app_scaffold/lib/main.dart`) | todo |

## Rules
- One task = one implementer invocation. Keep tasks small.
- A task is `done` only when docs/DefinitionOfDone.md is satisfied.
- ⛔BLOCKED tasks require the referenced Open Question answered before starting.
