---
name: delegate-to-devin
description: Spawn and steer Devin sessions in Devin's cloud for delegated stages of work. Current path is curl against the Devin v1 REST API using an `apk_user_` personal token; the MCP v3 path is the eventual target but requires a `cog_` service-user key we don't have yet. Sessions are persistent and resumable; every supervisor handoff (initial spawn or follow-up) MUST schedule a wake-up so the supervisor returns to read Devin's response. This skill is pure mechanics; the caller decides when to use Devin vs Codex vs Claude.
---

# delegate-to-devin

Drive a Devin session from a supervisor Claude session. Devin runs in its own cloud sandbox, so the supervisor must arrange to be re-summoned when Devin replies — there is no "callback" otherwise.

## Why curl + v1 (and not the MCP) right now

The Devin MCP server (`https://mcp.devin.ai/mcp`) is v3-only and rejects `apk_user_` personal tokens for write operations: handshake passes, but `devin_session_interact` returns `403 Forbidden`. The same token works fully against the v1 REST endpoints (`https://api.devin.ai/v1/...`) — session create, send_message, status reads all succeed.

Until someone provisions a `cog_` service-user key in Devin Settings → Service users, we stay on v1. Once we have one, see **Future: MCP migration** at the bottom of this file.

## Hard rules

1. **Always schedule a return.** Every time you hand off to Devin — whether spawning a new session or sending a follow-up message — call `ScheduleWakeup` (or `CronCreate` if you need a persistent recurrence) before yielding. Fire-and-forget is a bug: the supervisor never returns to read the response.
2. **Never inline-poll.** No `while` loops, no `sleep` chains in the supervisor. The helper script polls internally for its own settlement deadline; that's fine. Anything outside that helper goes through `ScheduleWakeup`.
3. **Don't paste tokens into shell args.** Use `$DEVIN_API_KEY` from env; never hard-code keys in scripts or commit them.

## Prerequisites

- `DEVIN_API_KEY` in env (`apk_user_…` form is acceptable for v1).
- `curl` and `jq` on `PATH`.
- Handoff dirs: `.orchestrator/handoff/` and `.orchestrator/schemas/` (created on demand).
- The `delegate-to-devin` helper at `plugins/orchestrator-skills/scripts/delegate-to-devin` for the initial-spawn case.

## Workflow A — initial delegation

1. **Write the prompt** to `.orchestrator/handoff/<stage>-prompt.md`. Tell Devin to keep `structured_output` updated and to conform to the schema below.

2. **Write the JSON schema** for `structured_output` to `.orchestrator/schemas/<stage>.json`. Default research schema:

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

3. **Create the session.** Two options — the helper is simpler; raw curl is when you need full control over the create payload or a non-blocking spawn.

   *Helper (preferred for one-shot research):*
   ```
   plugins/orchestrator-skills/scripts/delegate-to-devin \
     --prompt-file .orchestrator/handoff/<stage>-prompt.md \
     --schema-file .orchestrator/schemas/<stage>.json \
     --output      .orchestrator/handoff/0X-<stage>.md \
     --tag         <task-id> \
     [--repos repo1,repo2,...] \
     [--acu-limit N] \
     [--title "Short session title"] \
     [--poll-timeout 60]   # short timeout if you want to ScheduleWakeup yourself rather than block
   ```

   *Raw curl (non-blocking spawn):*
   ```bash
   curl -fsS -X POST https://api.devin.ai/v1/sessions \
     -H "Authorization: Bearer $DEVIN_API_KEY" \
     -H "Content-Type: application/json" \
     -d "$(jq -n --arg prompt "$(cat .orchestrator/handoff/<stage>-prompt.md)" \
                  --arg title "<short title>" \
                  --argjson acu 10 \
                  '{prompt: $prompt, title: $title, max_acu_limit: $acu, tags: ["<stage>"]}')"
   ```

   Capture `session_id` from the response.

4. **Schedule a wake-up.** Pick an interval that respects the prompt cache (`ScheduleWakeup` clamps to [60, 3600]):

   - Targeted follow-up question: 600s (10 min).
   - Multi-repo research: 1200–1800s (20–30 min) first check, re-schedule if still running.
   - Long codegen: 1800–3600s.

   The wake-up `prompt` must be self-contained: include the `session_id`, the handoff file path to write to, and the next-step instruction. Future-you needs to act without rebuilding context.

5. **Record the session** under `multiagent_task.sessions[]`:

   ```yaml
   - stage: <stage-name>
     agent: devin
     session_id: <from create response>
     url: https://app.devin.ai/sessions/<id>
     started_at: <iso>
     output_ref: .orchestrator/handoff/0X-<stage>.md
     status: pending
   ```

## Workflow B — follow-up question to an existing session

1. **Send via curl:**
   ```bash
   curl -fsS -X POST "https://api.devin.ai/v1/sessions/<session_id>/message" \
     -H "Authorization: Bearer $DEVIN_API_KEY" \
     -H "Content-Type: application/json" \
     -d "$(jq -n --arg m "<follow-up text>" '{message: $m}')"
   ```
2. **Immediately schedule a wake-up** (typical: 600s). No exceptions.
3. On wake-up, follow Workflow C.

## Workflow C — checking on a session

1. **Get status + messages in one shot:**
   ```bash
   curl -fsS "https://api.devin.ai/v1/sessions/<session_id>" \
     -H "Authorization: Bearer $DEVIN_API_KEY" \
     -o /tmp/devin-session.json
   jq '{status, status_enum, last: (.messages[-1] | {type, ts: .timestamp, head: ((.message // "") | .[0:200])})}' /tmp/devin-session.json
   ```
   Note the field on each message is `.message` (not `.content`).

2. **If still running** (`status_enum` ∈ `working`, `running`, `claimed`): re-schedule another wake-up (typical: 600–1200s). Do NOT block. Do NOT spin.

3. **If settled** (`status_enum` ∈ `finished`, `done`, `blocked`, `errored`):
   - Read the latest assistant message(s): `jq -r '.messages[-1].message' /tmp/devin-session.json`.
   - If a real `structured_output` is present (`jq '.structured_output' /tmp/devin-session.json` not `null`), render it; otherwise extract the inline brief from the latest message.
   - Append to the recorded `output_ref` markdown file.
   - Update `multiagent_task.sessions[].status` and `.settled_at`.
   - Surface a short summary to the operator.

4. **If blocked / errored:** check the latest message for the reason. Devin's VM can be unreachable mid-session; Devin will say so and inline the result. Don't treat that as a hard failure — extract whatever Devin actually delivered.

## Model selection

Devin's session-create payload accepts an agent/model selector when the API exposes one (the v1 endpoint historically just inherits the org default). Defaults are set at the org level in Devin's UI.

- **Research / synthesis / structured-output tasks** → smaller model (Sonnet-equivalent). Cheaper, faster, sufficient.
- **Novel design / cross-file refactor / hard reasoning** → larger model (Opus-equivalent).
- When unsure, default smaller and upgrade only if Devin reports it can't make progress.

## Failure modes

| Symptom | Likely cause | What to do |
|---|---|---|
| `status_enum: blocked` and last message says VM unreachable | Devin infra issue; sandbox down | Read the inline answer (Devin often delivers anyway via DeepWiki). Record and move on — not a hard failure. |
| `status_enum: blocked` and last message asks a question | Devin needs input | Send `POST /v1/sessions/{id}/message` with the answer; schedule wake-up. |
| `401 Unauthorized` from v1 | Token expired or wrong | Surface to operator; do not silently retry. Confirm `DEVIN_API_KEY` is set and current. |
| `403 Forbidden` on `/v3/organizations/.../sessions/...` | You accidentally hit the MCP/v3 path with an `apk_user_` token | Stay on v1 (`/v1/sessions/...`). For v3 you'd need a `cog_` service-user key. |
| Helper exits with "polling timed out" but session still running | Helper's poll deadline reached, Devin still working | This is fine — read the session via curl (Workflow C). The helper's exit code is not a Devin failure. |
| Wake-up never fires | `ScheduleWakeup` not called | Check immediately — if no wake-up is in flight, schedule one now and apologise to the operator. |

## Anti-patterns

- **Fire-and-forget after sending a message.** Always pair `send_message`/`message` with `ScheduleWakeup`.
- **Polling in a tight loop / sleeping inside the supervisor.** Use `ScheduleWakeup` and let the runtime hand control back.
- **Re-trying after 401/403 with the same token.** Surface the failure; don't paper over it.
- **Hard-coding tokens.** Use `$DEVIN_API_KEY`.
- **Trusting vendor docs about key/endpoint compatibility without verifying.** Confirmed gaps: `apk_user_` tokens work for v1 fully, fail at the v3 write layer despite passing the MCP handshake.

## Future: MCP migration

Once a `cog_` org-scoped service-user key is minted (Devin Settings → Service users), we move to the MCP path:

1. Update env: `DEVIN_API_KEY=cog_…`.
2. Re-register the MCP:
   ```
   claude mcp remove devin -s user
   claude mcp add -s user -t http devin https://mcp.devin.ai/mcp \
     -H "Authorization: Bearer $DEVIN_API_KEY"
   ```
   Org-scoped service-user keys resolve org_id automatically — no `X-Org-Id` needed.
3. Restart Claude Code to pick up the new tool surface.
4. Verify with `ToolSearch` for `mcp__devin__devin_session_interact`; if present, switch the workflows above to use the MCP tools in place of curl. The hard rules (schedule wake-up, no inline polling) are unchanged.

At that point this skill should be edited to invert: MCP becomes the documented happy path, curl becomes the v1 fallback only when MCP is unreachable.
