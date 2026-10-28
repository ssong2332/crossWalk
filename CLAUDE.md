# CLAUDE.md — Project Rules

## Prohibitions (override all other rules)
- No success reports without evidence (file:line, log, number).
- No unrequested modifications, refactoring, or deletions.
- No silent workarounds — report the blocker and get approval first.
- No guesses stated as facts — mark them as estimates and say how to verify.

## Project Overview
- Name: `crosswalk_app` (`crosswalk_app/pubspec.yaml:1`)
- Goal: On-device (offline, 추정) mobile app that warns a visually impaired user in real time, via voice + vibration, when they drift left/right off a crosswalk while crossing. (`docs/PRD.md` Goal, citing `pubspec.yaml:2`, `crosswalk_app/lib/services/feedback_service.dart:30-38`)
- Stack: Flutter (Dart, SDK `>=3.0.0 <4.0.0`), plain `StatefulWidget`/`setState`. Key packages (`crosswalk_app/pubspec.yaml:10-20`): `camera` ^0.11.0+2, `onnxruntime` ^1.4.0, `image` ^4.1.7, `flutter_tts` ^4.0.2, `vibration` ^2.0.0, `permission_handler` ^11.3.0, `wakelock_plus` ^1.2.5, `crypto` ^3.0.3 (integrity check currently disabled). Full rationale: `docs/Architecture.md` section 2.

## Verified Commands
Record commands verbatim after the first success. Reuse without modification; if a change is needed, state what and why first.

| Purpose | Command | Verified on |
|---|---|---|
| Build | `flutter build apk --release` (run from `crosswalk_app/`) | CI only — GitHub Actions run `29471306750` and others in `docs/Tasks.md` (T21–T28 rows), "APK 빌드" step succeeds after tests pass. **Not verified as a standalone local success**: T28 (`docs/Tasks.md` T28) added a guard in `crosswalk_app/android/app/build.gradle.kts` requiring `GITHUB_ACTIONS=true` or `-PallowDebugSigningForRelease=true`; a bare local run fails by design without one of these. Even with the opt-in flag, T28's own reviewer hit a separate unresolved native cmake/NDK toolchain failure locally. No fully-successful local build exists this session — CI is the only verified source. |
| Test (CI) | `flutter test` (run from `crosswalk_app/`) | CI — GitHub Actions run `29482819510` (`docs/Tasks.md` T11), "18 tests passed". |
| Test (local, this Windows PC) | Git Bash: `mkdir -p build/test_tmp && TEMP="$(pwd -W)/build/test_tmp" TMP="$(pwd -W)/build/test_tmp" /c/flutter/bin/flutter.bat test` — PowerShell: `New-Item -ItemType Directory -Force build\test_tmp \| Out-Null; $env:TEMP = "$PWD\build\test_tmp"; $env:TMP = $env:TEMP; C:\flutter\bin\flutter.bat test` (both run from `crosswalk_app/`) | LOCAL, 2026-10-20, commit `1ad935d`, Flutter 3.32.2 (same as CI) — both forms "+339: All tests passed!". Root cause of the old T9/T10/T11/T26 suite-load crash: with default `TEMP=C:\Users\박수홍\AppData\Local\Temp`, `flutter_tester.exe` exits `-1073740791` (0xC0000409) even on an empty test → "Connection closed before test suite loaded". Pointing `TEMP`/`TMP` (this command only) to an ASCII path fixes it. `flutter` is not on PATH — use `C:\flutter\bin\flutter.bat`. PowerShell form changes `TEMP` for that shell session only. **The checkout/worktree path must also be ASCII-only**: from a worktree under a non-ASCII path (`C:\Users\박수홍\...\scratchpad\wt-t109`) the same command still crashes the same way (2026-10-21, reproduced 2×); from `C:\vibecoding\crossWalk\.claude\worktrees\t109-fov` it passed "+368: All tests passed!" (2026-10-21). |
| Run | Not yet verified — no device/emulator was used this session; do not guess a command. | — |
| Field log analysis (T106) | `PYTHONIOENCODING=utf-8 python train/field_log_t106.py logs/log_20261002_123306.jsonl --out train/field_t106/20261002 --video videos/Screen_Recording_20261002_*.mp4` (run from repo root; replace log/out/video names per test) | LOCAL, 2026-10-02, commit `244d1c0` — report.md + summary.json + frames written; without `PYTHONIOENCODING=utf-8` the final console print crashes (cp1252) after outputs are written. |
| Field log self-test (T106) | `PYTHONIOENCODING=utf-8 python train/field_log_t106.py --selftest` (run from repo root) | LOCAL, 2026-10-02 — "자체 검증: 통과" (22 items) |
| H0 FOV eval re-run (T109) | `PYTHONIOENCODING=utf-8 python -c "import sys; from pathlib import Path; sys.path.insert(0,'train'); sys.argv=['x']; import h0_t109_eval as m; m.OUT=Path('train/h0_t109/rerun_1020').resolve(); m.main()"` (run from repo root; needs `videos/h0/` and `videos/h0/night/`; writes to `train/h0_t109/rerun_1020/` so the committed 10/17 outputs are not overwritten; the script creates the folder) | LOCAL, 2026-10-21 — exit 0; `frames.csv` byte-identical (`cmp`) and `summary.json` equal to the 2026-10-17 run (models `be0760b94af9`/`32c9d1964a21`/`128996645c45`). |
| Tactile false-alarm replay (T148) | `PYTHONIOENCODING=utf-8 python <worktree>/train/t148_tactile_yellow.py --sheet <worktree>/train/t148/sheet.jpg` (run from the main checkout root `C:/vibecoding/crossWalk`, which has `logs/` and `train/frames_1028b`, `train/frames_1026`; writes `train/t148/` next to the script) | LOCAL, 2026-10-28 — exit 0; events.csv + summary.json + sheet.jpg written (`train/t148_report.md`). |

Additional note: `flutter analyze` (run from `crosswalk_app/`) — verified LOCALLY, multiple times this session, directly executed on this dev machine; consistently produces the same 6 known pre-existing lint issues, no crash. `flutter pub get` is implicitly verified as a prerequisite of the CI runs above and as a side effect of local `flutter analyze` runs (dependencies resolved successfully).

## Report Template
```
### 결론: {한 줄 — 됐는가/안 됐는가/얼마나}
| 항목 | 결과 | 이전/기준값 | 근거 (파일:줄, 로그, 수치) |
### 문제/다음 단계: {있으면}
```

## Agent Workflow
- Agent contract (I/O, ownership, priority): AGENTS.md
- How to invoke agents: docs/PromptRules.md
- Completion criteria: docs/DefinitionOfDone.md
- Git rules: docs/GitWorkflow.md
