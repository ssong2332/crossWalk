# Coding Rules — {{project-name}}

Owner: User (architect may draft on request). All agents read-only.

## Prohibitions
- No new dependencies without an entry in DECISIONS.md.
- No commented-out code in commits.
- No `any`/untyped escapes where the language supports types.

## Naming
| Target | Convention | Example |
|---|---|---|
| Files | {{kebab-case / PascalCase / ...}} | {{...}} |
| Functions | {{camelCase / snake_case}} | {{...}} |
| Classes/Types | {{PascalCase}} | {{...}} |
| Constants | {{UPPER_SNAKE}} | {{...}} |

## Directory Rules
| Path | Contains | Must not contain |
|---|---|---|
| {{src/domain}} | {{business logic}} | {{framework imports}} |
| {{src/api}} | {{...}} | {{...}} |

## Style
- Formatter: {{prettier/black/... + config location}}
- Linter: {{eslint/ruff/... + config location}}
- Max function length: {{n}} lines (guideline, not hard rule)

## Error Handling
{{project pattern — e.g., Result type / exceptions at boundary only}}

## Tests
- Location: {{tests/ or co-located}}
- Naming: {{test_*.py / *.test.ts}}
- Minimum: every P0 feature has at least one happy-path and one failure-path test.
