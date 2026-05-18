---
name: delegate-to-codex
description: Send a message to a named Codex agent — spawns it fresh on first call, resumes via `codex resume <session-id>` on subsequent calls, sends to a live pane if one is already running. Driven by the `send-agent` utility which abstracts the three branches behind one entry point. Codex writes its output directly to a handoff file in the worktree; only a short pointer comes back.
---

# delegate-to-codex

The supervisor calls **`send-agent`** with `--agent codex` and a name. The utility decides whether to spawn, resume, or send-to-live based on what state files exist under `.orchestrator/sessions/<name>.*`. Symmetric with `delegate-to-claude`.

## Prerequisite

The `codex` CLI must be on PATH:

```bash
which codex
codex --version
```

If missing, install per OpenAI's instructions and run `codex login` once (or set `OPENAI_API_KEY`).

The legacy `codex-plugin-cc` Claude Code plugin (`/codex:rescue` etc.) is **not** used — it runs Codex as an invisible Node subprocess and isn't loaded in agent-spawned sessions. `send-agent` calls the `codex` CLI directly in a craft-mux pane.

## Invocation

```bash
"$CRAFT_ROOT/plugins/orchestrator-skills/scripts/send-agent" "task-<id>-<stage>" \
    --agent codex \
    --worktree "$WORKTREE" \
    --model "$MODEL" \
    --message-file ".orchestrator/handoff/<stage>-prompt.md"
```

The utility:
1. Augments your prompt with the standardised done-sentinel footer.
2. Snapshots `~/.codex/sessions/` before spawning so it can capture the new session id by diff after.
3. Spawns / resumes / sends as appropriate.
4. Blocks until `.orchestrator/sessions/<name>.done` is touched.
5. Captures the codex session id into `.orchestrator/sessions/<name>.id`.

## Prompt convention (just the part you write)

The utility adds the sentinel footer. You only need to write the work-specific part:

- **Goal + inputs** — point Codex at the task file in `queue/in-progress/` and any prior handoff files it should read.
- **Output path** — where Codex must write its summary (e.g. `.orchestrator/handoff/0X-<stage>.md`).
- **"Reply briefly"** — return only `ok` + the handoff path. Do NOT paste the diff.

## Prompt example (what you pass via --message-file)

```
Implement the changes described in queue/in-progress/<task-id>.md
(and any research findings in .orchestrator/handoff/01-research.md if present).

Constraints:
- All work must stay in this worktree.
- After committing, append a brief summary to .orchestrator/handoff/02-execute.md
  with: files touched, key decisions, anything skipped.

Reply with only "ok" — the supervisor will read the summary file.
```

## Recording the session

The utility writes `.orchestrator/sessions/<name>.id` (extracted from `~/.codex/sessions/`). Append a record to `multiagent_task.sessions[]`:

```yaml
    - stage: <stage-name>
      agent: codex
      session_id: <from .orchestrator/sessions/<name>.id>
      url: ""
      model: <as passed to --model>
      effort: ""
      cwd: <worktree absolute path>
      pane: ""                     # ephemeral; session_id is the durable handle
      started_at: <ISO-8601>
      settled_at: <ISO-8601>
      output_ref: .orchestrator/handoff/0X-<stage>.md
      summary: <one-line summary>
```

## Resurrection / follow-ups

Same as Claude — call `send-agent` again with the **same name**. The utility sees the recorded session id and resumes via `codex resume`.

```bash
send-agent "task-042-execute" --agent codex --worktree "$WORKTREE" \
    --message "Create a draft PR for the changes you just made. ..."
```

## Interactive peek

To attach a human terminal:

```bash
cd <worktree>
codex resume <session-id>
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `codex: command not found` after spawn | Codex CLI not on PATH (or not on the spawned shell's PATH) | Install codex; verify `which codex` from the worktree dir. |
| Codex hangs on first prompt | Approval-mode interaction wanted | Pass `--dangerously-bypass-approvals-and-sandbox` (already in send-agent's invocation) or set `CODEX_APPROVAL_MODE=bypass` in `craft.conf`. |
| Codex exits immediately with auth error | Not authenticated | `codex login`, or set `OPENAI_API_KEY` env before spawning. |
| Done sentinel never appears, pane is closed | Codex exited before writing it | Read the expected handoff file directly — Codex commits in-progress. If missing, inspect `~/.codex/sessions/<latest>.jsonl` for the conversation trail. |
| Session id capture failed (warning from send-agent) | Multiple codex sessions started concurrently | Re-run with `--lock-timeout`, or grep `~/.codex/sessions/` for the right session by date/cwd and manually write to `.orchestrator/sessions/<name>.id`. |
