# AGENTS.md — Agent Contract

This document is the contract between the six project agents. It defines what each agent consumes, produces, may modify, and which documents it owns.

## Prohibitions (override all other rules)
- No agent modifies a document or file it does not own (see Ownership table).
- planner, architect, docs: never modify source code.
- reviewer, quality-assurance: never modify any file. Output is a report only.
- No agent invents requirements. Unclear requirements become Open Questions in the report.
- No agent waits for approval mid-run. Report items needing approval, then finish.

## Pipeline

```
planner → [user approval] → architect → [user approval] → implementer
        → reviewer / quality-assurance → (fixes: implementer again) → docs
```

- Issues found by reviewer/quality-assurance go back to implementer with the report.
- Design-level defects go back to architect first, then implementer.
- implementer must satisfy docs/DefinitionOfDone.md before handing off to reviewer/quality-assurance.

## Authority

Each agent acts only within its authority. An agent must never perform work outside its authority unless explicitly instructed by the user.

| Agent | Authority |
|---|---|
| planner | Planning only |
| architect | Technical design only |
| implementer | Code only |
| reviewer | Review only |
| quality-assurance | Validation only |
| docs | Documentation only |

## Agent Contract Table

| Agent | Input (consumes) | Output (produces) | May modify |
|---|---|---|---|
| planner | User request, docs/DECISIONS.md | docs/PRD.md, docs/Tasks.md, Open Questions report | docs/PRD.md, docs/Tasks.md only |
| architect | docs/PRD.md | docs/Architecture.md, docs/API.md (if required), docs/Database.md (if required), docs/DECISIONS.md entries, docs/adr/ records, design report | docs/Architecture.md, docs/API.md, docs/Database.md, docs/DECISIONS.md, docs/adr/ only |
| implementer | docs/PRD.md, docs/Architecture.md, docs/CodingRules.md, docs/GitWorkflow.md, docs/Tasks.md, docs/API.md, docs/Database.md, docs/DefinitionOfDone.md | Source code, implementation report | Source code only (recommend doc updates; never silently change docs) |
| reviewer | git diff (preferred), files explicitly specified by the caller, project documentation, docs/GitWorkflow.md | Review report | Nothing |
| quality-assurance | git diff (preferred), files explicitly specified by the caller, project documentation, docs/DefinitionOfDone.md | Test report | Nothing |
| docs | Project changes (git diff), all project documentation | Updated documentation, documentation summary | README.md and all files under docs/ |

## Document Ownership

| Document | Owner (creates/updates) | Everyone else |
|---|---|---|
| CLAUDE.md | User | Read-only |
| AGENTS.md | User | Read-only |
| README.md | docs | Read-only |
| docs/PRD.md | planner | docs may sync; others read-only |
| docs/Tasks.md | planner | docs may sync; others read-only |
| docs/Architecture.md | architect | docs may sync; others read-only |
| docs/API.md | architect | docs may sync; others read-only |
| docs/Database.md | architect | docs may sync; others read-only |
| docs/DECISIONS.md | architect | docs may sync; others read-only |
| docs/adr/ | architect | Read-only (ADRs are immutable once accepted) |
| docs/CodingRules.md | User (or architect on request) | Read-only |
| docs/GitWorkflow.md | User | Read-only (implementer follows) |
| docs/DefinitionOfDone.md | User | Read-only (implementer/QA enforce) |
| docs/PromptRules.md | User | Read-only |
| docs/CHANGELOG.md | docs | Read-only |
| Source code | implementer | Read-only |

## Document Priority

Each agent's own file defines which documents are Required (always read if available) vs. Optional (read only when relevant to the current task) — this keeps agents from burning context on documents outside their role. When documents an agent actually reads conflict, the higher-priority one below takes precedence:

1. CLAUDE.md
2. AGENTS.md
3. README.md
4. docs/PRD.md
5. docs/Architecture.md
6. docs/DECISIONS.md
7. docs/adr/
8. docs/CodingRules.md
9. docs/GitWorkflow.md
10. docs/DefinitionOfDone.md
11. docs/Tasks.md
12. docs/API.md
13. docs/Database.md
14. docs/PromptRules.md
15. docs/CHANGELOG.md

## Project Structure

```
project/
├── CLAUDE.md
├── AGENTS.md
├── README.md
└── docs/
    ├── PRD.md
    ├── Architecture.md
    ├── Tasks.md
    ├── CodingRules.md
    ├── Database.md
    ├── API.md
    ├── CHANGELOG.md
    ├── DECISIONS.md
    ├── DefinitionOfDone.md
    ├── GitWorkflow.md
    ├── PromptRules.md
    └── adr/
        └── 0001-....md
```
