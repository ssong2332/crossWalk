# CLAUDE.md — Project Rules

## Prohibitions (override all other rules)
- No success reports without evidence (file:line, log, number).
- No unrequested modifications, refactoring, or deletions.
- No silent workarounds — report the blocker and get approval first.
- No guesses stated as facts — mark them as estimates and say how to verify.

## Project Overview
- Name: {{project-name}}
- Goal: {{one line}}
- Stack: {{fill in after docs/Architecture.md is approved}}

## Verified Commands
Record commands verbatim after the first success. Reuse without modification; if a change is needed, state what and why first.

| Purpose | Command | Verified on |
|---|---|---|
| Build | {{...}} | {{date}} |
| Test | {{...}} | {{date}} |
| Run | {{...}} | {{date}} |

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
