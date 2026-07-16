# Git Workflow — {{project-name}}

Owner: User. implementer follows; reviewer checks compliance.

## Prohibitions
- No direct commits to `main`.
- No force-push to shared branches.
- No `--no-verify` / hook skipping.
- No commit without a passing local test run.

## Branches
| Type | Pattern | Example |
|---|---|---|
| Feature | `feat/{{task-id}}-{{slug}}` | feat/T3-login-form |
| Fix | `fix/{{task-id}}-{{slug}}` | fix/T7-null-token |
| Docs | `docs/{{slug}}` | docs/update-api |

## Commit Messages
```
{{type}}: {{summary ≤ 50 chars}}

{{body — what and why, not how}}

Refs: {{task ID}}
```
Types: `feat` / `fix` / `refactor` / `docs` / `test` / `chore`

## Merge Rules
- One task (docs/Tasks.md ID) = one branch = one PR.
- PR merges only after docs/DefinitionOfDone.md checklist passes.
- Squash-merge {{or merge-commit — pick one}}.
