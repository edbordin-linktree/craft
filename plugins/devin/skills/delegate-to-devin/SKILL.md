---
name: delegate-to-devin
description: Spawn Devin cloud sessions for delegated work and consume the result through Craft task events. Use when the task agent wants to hand a bounded research, synthesis, or implementation subtask to Devin without blocking its own terminal.
---

# delegate-to-devin

Drive a Devin session from inside a Craft task. Devin runs in its own cloud sandbox; Craft records the session and the `devin` plugin checks it from the orchestrator poll loop. When Devin settles, Craft writes the configured output file and queues a task event.

## Hard rules

1. **Do not poll Devin yourself.** No `while`, no `sleep`, no manual recurring status checks from the task agent.
2. **Wait on Craft events.** After starting a session, use `craft event list` or `craft event take` for `devin.session_settled` / `devin.session_failed`.
3. **Do not run background helpers.** The `devin` plugin `on_poll` hook performs settlement checks from the orchestrator.
4. **Do not paste tokens into shell args.** Use `$DEVIN_API_KEY` from env.

## Prerequisites

- `DEVIN_API_KEY` in env (`apk_user_...` works for the current v1 REST path).
- `curl` and `jq` on `PATH`.
- The project has the `devin` plugin enabled so its `on_poll` hook can publish settlement events.
- Handoff dirs such as `.orchestrator/handoff/` and `.orchestrator/schemas/` exist or can be created.

## Initial Delegation

1. Write the prompt to `.orchestrator/handoff/<purpose>-prompt.md`.

2. Write the JSON schema for `structured_output` to `.orchestrator/schemas/<purpose>.json`. Default research schema:

   ```json
   {
     "type": "object",
     "required": ["summary", "findings", "recommendations"],
     "properties": {
       "summary": { "type": "string" },
       "findings": {
         "type": "array",
         "items": {
           "type": "object",
           "properties": {
             "repo": { "type": "string" },
             "file": { "type": "string" },
             "observation": { "type": "string" }
           }
         }
       },
       "recommendations": { "type": "array", "items": { "type": "string" } },
       "follow_ups": { "type": "array", "items": { "type": "string" } }
     }
   }
   ```

3. Create the session:

   ```bash
   plugins/devin/scripts/delegate-to-devin \
     --prompt-file .orchestrator/handoff/<purpose>-prompt.md \
     --schema-file .orchestrator/schemas/<purpose>.json \
     --output      .orchestrator/handoff/<purpose>-devin.md \
     --tag         "$CRAFT_TASK_ID" \
     --title       "Short session title" \
     --acu-limit   10
   ```

   The helper returns immediately with JSON like:

   ```json
   {
     "session_id": "...",
     "url": "https://app.devin.ai/sessions/...",
     "output_path": ".../.orchestrator/handoff/<purpose>-devin.md",
     "status": "pending",
     "session_record": ".../.orchestrator/devin/sessions/<id>.json",
     "event_type": "devin.session_settled"
   }
   ```

4. Continue other work or wait for the event. To inspect without consuming:

   ```bash
   craft event list --type devin.session_settled --type devin.session_failed
   ```

   To consume the result:

   ```bash
   craft event take --type devin.session_settled --limit 1
   ```

5. Read the event payload and then read `payload.output_path`. That output file is the source of truth for Devin's structured result.

## Event Contract

`devin.session_settled` payload:

```json
{
  "session_id": "...",
  "url": "https://app.devin.ai/sessions/...",
  "output_path": ".../.orchestrator/handoff/<purpose>-devin.md",
  "status": "blocked|completed|finished|done|...",
  "started_at": "2026-06-01T00:00:00Z",
  "settled_at": "2026-06-01T00:10:00Z",
  "summary": "Short summary extracted from structured_output"
}
```

`devin.session_failed` payload:

```json
{
  "session_id": "...",
  "url": "https://app.devin.ai/sessions/...",
  "status": "failed|errored|cancelled",
  "settled_at": "2026-06-01T00:10:00Z"
}
```

## Follow-Up Question

For now, send follow-ups with the REST API and then wait for the next Craft event. Do not poll manually:

```bash
curl -fsS -X POST "https://api.devin.ai/v1/sessions/<session_id>/message" \
  -H "Authorization: Bearer $DEVIN_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg m "<follow-up text>" '{message: $m}')"
```

The existing session record remains pending only until the first settlement event. If you need multiple structured follow-ups, start a new `delegate-to-devin` session with a fresh output file.

## Failure Modes

| Symptom | Likely cause | What to do |
|---|---|---|
| No event appears | Orchestrator has not polled yet, plugin not enabled, or `DEVIN_API_KEY` missing from orchestrator env | Check `craft event list --type devin.session_settled --type devin.session_failed`; if empty after a few orchestrator polls, surface to operator. |
| `devin.session_failed` | Devin returned failed/errored/cancelled or no structured output | Open the Devin URL for context, then decide whether to retry with a clearer prompt. |
| `401 Unauthorized` from helper | Token expired or wrong | Surface to operator; do not retry with the same token. |
| `403 Forbidden` on v3/MCP | `apk_user_` token cannot write through v3 | Stay on v1 REST until a `cog_` service-user key exists. |

## API Notes

The Devin MCP server (`https://mcp.devin.ai/mcp`) is v3-only and rejects `apk_user_` personal tokens for write operations. The v1 REST endpoint works with current personal tokens for session creation and status reads.

When a `cog_` org-scoped service-user key is available, this plugin can move to the MCP/v3 path. The Craft event contract should stay the same.
