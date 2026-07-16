# Database — {{project-name}}

Owner: architect (see AGENTS.md). Others read-only.
Created only when the project requires a database (architect: "if required").

## Engine
{{PostgreSQL 16 / SQLite / ...}} — reason in DECISIONS.md.

## Schema
### {{table_name}}
| Column | Type | Constraints | Description |
|---|---|---|---|
| id | {{...}} | PK | |
| {{...}} | {{...}} | {{...}} | {{...}} |

## Relationships
{{ERD or list — table_a 1:N table_b}}

## Indexes
| Table | Index | Reason |
|---|---|---|
| {{...}} | {{...}} | {{query it serves}} |

## Migration Policy
{{tool and rules — e.g., all changes via migration files, never manual DDL}}
