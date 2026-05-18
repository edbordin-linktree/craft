# orchestrator-skills

A craft plugin that wires together the per-task agent flow:

1. **Codex** does the coding (configurable via `DEFAULT_AGENT`).
2. **Cross-model review** is delegated to a different agent (default: Claude Sonnet via `claude -p`), so self-review bias is sidestepped. Findings land as inline diffhub comments + a markdown handoff.
3. A **local review phase** (new `diffhub-review` queue state) lets the human and bot reviewers comment in parallel via diffhub. The agent addresses each comment as it arrives. A 2-hour idle timeout auto-advances overnight runs to the PR phase once chatter dies down.
4. **`babysit-pr`** then handles the github PR through merge — CI fixes, late human comments, base-branch conflicts.

## Architecture in one diagram

```
work-task (Codex by default)
  ├── Step 6   push branch (no PR yet)
  ├── Step 7   review-pr → spawns claude sonnet reviewer in background
  │              writes inline diffhub comments + .orchestrator/handoff/review.md
  ├── Step 8   move to queue/diffhub-review/, run babysit-diffhub loop
  │              (human + bot comments mingle; address each in arrival order;
  │               exit on .orchestrator/ready-for-pr sentinel OR 2h idle)
  ├── Step 9   gh pr create --draft && gh pr ready  →  queue/waiting/
  ├── Step 10  invoke babysit-pr skill until merge
  └── Step 11  queue/done/
```

## What it installs into each project

Into both `.claude/skills/` and `.codex/skills/` (so discovery works for both
Claude Code and Codex CLI):

| Skill | Used by | Purpose |
|---|---|---|
| `delegate-to-devin` | Architect | Cross-repo research via the Devin REST API |
| `architect-delegation` | Architect | When/how the architect may delegate during planning |
| `review-pr` | Reviewer sub-agent | Rubric for the local review (severity bands, security/perf checklists, comment conventions). Adapted from [mblode/agent-skills](https://github.com/mblode/agent-skills) (MIT) |
| `babysit-pr` | Work-task agent (Step 10) | Phase-split github PR babysitter with watch-pr background script |
| `cmux` | Reference | cmux CLI + socket API reference |

Slash commands stay `.claude/`-only (codex has no equivalent feature).

## Scripts (invoked by path, not auto-installed)

Under `plugins/orchestrator-skills/scripts/`:

- **`review-pr`** — spawns the cross-model reviewer headless. Writes findings to `.git/diffhub-comments.json` (inline, tagged `automated-review:<reviewer>-<model>`) and `.orchestrator/handoff/review.md`. Pluggable: `--reviewer claude|codex|cursor|gemini` (only claude wired up today; TODOs at top for the others + parallel reviewers).
- **`babysit-diffhub`** — fast local watcher for the diffhub-review phase. Polls `.git/diffhub-comments.json` + the `.orchestrator/ready-for-pr` sentinel; writes transitions to `.orchestrator/diffhub-pending.md`. 2-hour idle timeout auto-touches the sentinel.
- **`watch-pr`** — GitHub PR watcher used by `babysit-pr`. Single GraphQL fetch per poll; captures conflicts, CI failures, new review threads + inline comments, base advances.
- **`delegate-to-devin`** — Bash helper that round-trips Devin REST API (create session, poll, render `structured_output` to file).
- **`send-agent`** — generic "send a message to a named agent" dispatcher (spawn fresh, resume existing, or send to live pane). Used in the archived multi-agent flow; retained because `delegate-to-devin` / `architect-delegation` patterns can still benefit from it.

## Configuration

### `craft.conf` defaults this plugin sets (via `on_install`)

- `DEFAULT_AGENT=codex` — the per-task coding agent. Override per-task with `agent:` in YAML frontmatter.

### `craft.conf` settings you may want

- `CODEX_APPROVAL_MODE=bypass` — fewer interactive prompts.
- `MULTIPLEXER=cmux` — if you're on cmux. Diffhub integrates cleanly here.
- `TASK_SKILL=<skill-name>` — override the orchestrator's per-task slash command (defaults to `work-task`). Useful for opting individual projects into bespoke flows.

### Plugin-level configuration

`plugin.conf` next to this README has tunables (install mode, Devin API key + ACU limit).

## Enabling

```bash
craft plugin add <project-name> orchestrator-skills
```

`craft plugin add` symlinks the plugin from `$CRAFT_ROOT/plugins/` into the project, then fires `on_install` which interactively offers to set `DEFAULT_AGENT=codex` if it isn't already.

## Architect access

`init-architect.md` (the craft default) doesn't need editing. The architect picks up the right delegation behaviour automatically via two channels:

- **`architect-delegation` skill** (auto-discovered) — names which tools the architect may delegate to (Devin via skill, Claude via native `Agent` tool) and what's off-limits (`/work-task`, the execution-side scripts).
- **`delegate-to-devin` skill** (auto-discovered) — mechanics for firing a Devin session during research.

## Archived

Under `archive/` and not installed by `on_poll`:

- `commands/multiagent-task.md` — supervisor + per-stage delegation flow.
- `skills/delegate-to-claude/` and `skills/delegate-to-codex/` — used by the old supervisor to delegate execute / review / planning stages to specialised sub-agents.

The orchestrator's `TASK_SKILL` configurability is retained — anyone wanting to revive the multi-agent flow can move files back out of `archive/` and set `TASK_SKILL=multiagent-task`.

## Open TODOs

- **Dashboard "approve" hotkey** in `bin/orchestrator.sh`: let the operator advance a task from `diffhub-review` → PR phase by hitting a key in the dashboard, which would `touch <worktree>/.orchestrator/ready-for-pr`. Today the human runs `touch` manually or tells the agent to.
- **`review-pr --reviewer codex|cursor|gemini`** — currently stubbed. Wire up real dispatch.
- **Parallel reviewers** — let `review-pr` spawn multiple models simultaneously, each writing findings with its own tag.
