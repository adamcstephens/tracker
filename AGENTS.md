## Agent Workflow
- **IMPORTANT**: before you do anything else, invoke the vein `orient` MCP prompt and heed its output with `/mcp__vein__orient`.

## Definition of done
- formatting done, `just format`
- tests pass, `just test`
- code committed with all ticket changes included
  - Ticket ID in the body
  - Co-Authored-By line always included
- *important* After committing, stop and get user approval for completion.
- ticket marked complete once approved

## Code conventions

- Prefer red/green TDD. If unsure what style of testing, stop and ask.
- Always read code for project elixir dependencies from `deps`. Never query hexdocs or hex.
- Remove dead code

## Testing

- Test nix end to end with `just check-e2e`
- You can access the dev server live over tidewave project_eval, allowing for introspection of a live environment.

## Workspace setup

After creating a workspace, run: `mix deps.get && mix compile`

