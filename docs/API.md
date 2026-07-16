# API — {{project-name}}

Owner: architect (see AGENTS.md). Others read-only.
Created only when the project exposes an API (architect: "if required").

## Conventions
- Base URL: {{/api/v1}}
- Auth: {{Bearer token / session / none}}
- Error format: {{shared error response shape}}

## Endpoints
### {{METHOD}} {{/path}}
| Item | Value |
|---|---|
| Purpose | {{...}} |
| Auth | {{required / none}} |
| Request | {{body/query schema}} |
| Response | {{200 schema}} |
| Errors | {{400/401/404 conditions}} |
