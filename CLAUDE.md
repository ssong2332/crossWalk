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
| Test | `flutter test` (run from `crosswalk_app/`) | CI only — GitHub Actions run `29482819510` (`docs/Tasks.md` T11), "18 tests passed". **Not verified locally**: `flutter_tester.exe` crashes at suite-load time on this dev machine for an unrelated, never-root-caused environment issue (documented in `docs/Tasks.md` T9/T10/T11/T26). |
| Run | Not yet verified — no device/emulator was used this session; do not guess a command. | — |

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
