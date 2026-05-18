---
name: delegate-to-claude
description: Send a message to a named Claude agent — spawns it fresh on first call, resumes via `claude --resume <session-id>` on subsequent calls, sends to a live pane if one is already running. Driven by the `send-agent` utility which abstracts the three branches behind one entry point. Output is written by Claude to a handoff file; only a short pointer comes back. NOT for task-level planning — that's the architect's role.
---

# delegate-to-claude

The supervisor calls **`send-agent`** with `--agent claude` and a name. The utility decides whether to spawn, resume, or send-to-live based on what state files exist under `.orchestrator/sessions/<name>.*`. Session continuity is invisible to the caller.

## When to use this vs the native Agent tool

| Scenario | Use |
|---|---|
| **Stage will need follow-ups** (execute → PR creation → CI fixes → review fixes) | `send-agent` — preserves session continuity across short-lived panes |
| **Mid-flight co-pilot pattern** (long-lived watcher pane receiving nudges) | `send-agent` — utility detects the live pane and uses `craft-mux send` |
| **Truly one-shot** (review a diff, summarise a doc) | Native `Agent` tool — no session, no panes, result lands inline. Cheaper. |

If unsure, default to the native Agent tool. Switch to `send-agent` only when you have a concrete reason — usually "I or babysit-pr will want to talk to the same author again."

## Invocation

```bash
"$CRAFT_ROOT/plugins/orchestrator-skills/scripts/send-agent" "task-<id>-<stage>" \
    --agent claude \
    --worktree "$WORKTREE" \
    --model "$MODEL" \
    --message-file ".orchestrator/handoff/<stage>-prompt.md"
```

The utility:
1. Augments your prompt with the standardised session-id + done sentinels (you don't write those).
2. Spawns / resumes / sends as appropriate.
3. Blocks until `.orchestrator/sessions/<name>.done` is touched by the agent.
4. Returns 0. The agent's full output is in your handoff path (per your prompt); the recorded session id lives in `.orchestrator/sessions/<name>.id`.

## Prompt convention (just the part you write)

The utility adds the sentinel footer. You only need to write the work-specific part:

- **Goal** — what to produce, in one or two sentences.
- **Inputs** — paths to read (task file in `queue/in-progress/`, prior handoff files).
- **Output path** — where to write the result (e.g. `.orchestrator/handoff/0X-<stage>.md`). The spawned Claude uses Write tool.
- **"Reply briefly"** — return only `ok` plus the handoff path. Do NOT paste the content back.

## Model selection

- `opus` — hard reviews, deep reasoning within a stage.
- `sonnet` — general implementation, most UI work.
- `haiku` — cheap one-shots, mechanical edits, light synthesis.

Pass via `--model`. On a resume, `--model` is ignored — the resumed session keeps its original model.

## Recording the session

The utility writes `.orchestrator/sessions/<name>.id`. Append a record to `multiagent_task.sessions[]`:

```yaml
    - stage: <stage-name>
      agent: claude
      session_id: <from .orchestrator/sessions/<name>.id>
      url: ""
      model: <opus|sonnet|haiku>
      cwd: <worktree absolute path>
      pane: ""                     # ephemeral; session_id is the durable handle
      started_at: <ISO-8601>
      settled_at: <ISO-8601>
      output_ref: .orchestrator/handoff/0X-<stage>.md
      summary: <one-line summary>
```

## Resurrection / follow-ups

Just call `send-agent` again with the **same name**. The utility sees the recorded session id and resumes via `claude --resume`. The agent retains memory across resumes — full prior context preserved.

```bash
send-agent "task-042-execute" --agent claude --worktree "$WORKTREE" \
    --message "Create a draft PR for the changes you just made. ..."
```

## Interactive peek

To attach a human terminal to a session:

```bash
cd <worktree>
claude --resume <session-id>
```
