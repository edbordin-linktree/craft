# orchestrator-skills

A craft plugin that wires together the per-task agent flow:

1. **Codex** does the coding (configurable via `DEFAULT_AGENT`).
2. **Cross-model review** is delegated to a different agent (default: Claude Sonnet via `claude -p`), so self-review bias is sidestepped. Findings land as inline diffhub comments + a markdown handoff.
3. A **local review phase** lets the human and bot reviewers comment in parallel via diffhub. `craft task state set ... diffhub-review --stage local_review` records the task state and fires the stage hook that starts `babysit-diffhub`.
4. **`babysit-pr`** then handles the github PR through merge. The `pr_review` stage hook opens PR visibility surfaces and starts `watch-pr`, which enqueues typed events for conflicts, CI, comments, approvals, and terminal merge/close states.

## Architecture in one diagram

```
work-task (Codex by default)
  ├── Step 6   push branch (no PR yet)
  ├── Step 7   review-pr → spawns claude sonnet reviewer in background
  │              writes inline diffhub comments + .orchestrator/handoff/review.md
  ├── Step 8   craft task state set diffhub-review --stage local_review
  │              lifecycle hook starts babysit-diffhub
  │              → craft event enqueue local_review/ready_for_pr/review_timeout
  ├── Step 9   craft task state set waiting --stage pr_review
  │              lifecycle hook opens PR surface + starts watch-pr
  ├── Step 10  craft event enqueue merge_status/ci_status/
  │              review_comment/pr_approval/pr_terminal until merge
  └── Step 11  queue/done/
```

## Runtime architecture

- **Pending-only typed event queue** — watchers call `craft event enqueue`. Agents never inspect queue storage directly; they drain with `craft event take --type ... --limit ...`, which returns batches and deletes consumed files.
- **Queue-summary wake-ups** — Craft sends a compact task-targeted message only on empty-to-non-empty transitions, for example `CRAFT_EVENTS task=task-123 pending=3 counts=local_review:2,ci_status:1`.
- **Task state command** — `craft task state set` is the one supported entrypoint for queue movement, frontmatter status/timestamps, stage updates, lifecycle hooks, and timestamped work-log entries.
- **Stage-owned side effects** — lifecycle hooks own deterministic runtime behavior: starting `babysit-diffhub` on `local_review`, opening/focusing PR surfaces and starting `watch-pr` on `pr_review`, and cleanup on `complete`, `blocked`, or `cleanup`.
- **Stable browser surfaces** — scripts call `craft surface open|focus|close`, not raw cmux placement. Craft stores stable surface IDs in `tasks/<task-id>/.orchestrator/surfaces.json`; current IDs are `diffhub-review`, `github-pr`, and `devin-session`.
- **Right-side browser pane reuse** — the cmux provider opens browser tabs in the task workspace's shared right-side browser pane and reuses same-workspace URL matches instead of scanning all workspaces.
- **Configured dashboard command** — `DASHBOARD_CMD` in `craft.conf` owns launching the dashboard server. Core Craft does not hardcode orchestrator-skills dashboard paths.
- **Devin visibility** — `delegate-to-devin` opens or reuses `https://app.devin.ai/sessions/<session_id>` as the `devin-session` surface when task context is available. The tab is for operator inspection; structured handoff files remain the source of truth.

## Plugin assets

Craft core syncs `plugins/orchestrator-skills/project/` into each enabled
project as symlinks. The plugin owns the Ed-specific command layer and skills;
the base Craft templates stay generic.

Installed `.claude/commands/` assets:

| Command | Purpose |
|---|---|
| `work-task` | Enhanced work-task flow: local diffhub review, cross-model review, PR babysitting |
| `init-architect` | Architect workflow with discoverer delegation guidance |
| `init-discoverer` | Discoverer workflow for scoping implementation tasks |

Installed into both `.claude/skills/` and `.codex/skills/` (so discovery works
for both Claude Code and Codex CLI):

| Skill | Used by | Purpose |
|---|---|---|
| `delegate-to-devin` | Architect | Cross-repo research via the Devin REST API |
| `architect-delegation` | Architect | When/how the architect may delegate during planning |
| `review-pr` | Reviewer sub-agent | Rubric for the local review (severity bands, security/perf checklists, comment conventions). Adapted from [mblode/agent-skills](https://github.com/mblode/agent-skills) (MIT) |
| `babysit-pr` | Work-task agent or manual PR babysitter | Phase-split github PR babysitter with watch-pr background script |
| `cmux` | Reference | cmux CLI + socket API reference |

## Scripts (invoked by path, not auto-installed)

Under `plugins/orchestrator-skills/scripts/`:

- **`review-pr`** — spawns the cross-model reviewer headless. Writes findings to `.orchestrator/handoff/review.md` and imports inline comments through diffhub's `/api/comments` REST API, tagged in the body as `automated-review:<reviewer>-<model>`. Pluggable: `--reviewer claude|codex|cursor|gemini` (only claude wired up today; TODOs at top for the others + parallel reviewers).
- **`babysit-diffhub`** — fast local watcher for the diffhub-review phase. Polls diffhub's read-only `/api/comments` endpoint and enqueues `local_review` / `review_timeout` events. Human and dashboard approval use `craft task signal ... ready_for_pr`.
- **`watch-pr`** — GitHub PR watcher used by `babysit-pr`. Single GraphQL fetch per poll; enqueues `merge_status`, `ci_status`, `review_comment`, `pr_approval`, `pr_review`, and `pr_terminal` events.
- **`delegate-to-devin`** — Bash helper that round-trips Devin REST API (create session, poll, render `structured_output` to file) and opens the `devin-session` browser surface when task context is available.
- **`send-agent`** — generic "send a message to a named agent" dispatcher (spawn fresh, resume existing, or send to live pane). Used in the archived multi-agent flow and retained for operators who still want that style of delegation.

## Configuration

### `craft.conf` defaults this plugin sets (via `on_install`)

- `DEFAULT_AGENT=codex` — the per-task coding agent. Override per-task with `agent:` in YAML frontmatter.

### `craft.conf` settings you may want

- `CODEX_APPROVAL_MODE=bypass` — fewer interactive prompts.
- `MULTIPLEXER=cmux` — if you're on cmux. Diffhub integrates cleanly here.
- `TASK_SKILL=<skill-name>` — optional escape hatch for a non-workflow task command. By default, Craft renders the resolved workflow prompt from the task's `workflow:` field and enabled plugin stages.

### Plugin-level configuration

`plugin.conf` next to this README declares `QUEUE_STATES=diffhub-review` and
has Devin API tunables. Craft core creates/renders the extra queue state.

## Enabling

```bash
craft plugin add <project-name> orchestrator-skills
```

`craft plugin add` enables the plugin in the project, fires `on_install`, then
uses Craft's generic project-asset sync to symlink commands and skills into the
project. `on_install` interactively offers to set `DEFAULT_AGENT=codex` if it
isn't already.

## Architect access

`init-architect.md` is plugin-owned once this plugin is enabled. The architect
picks up delegation behaviour from installed skills:

- **`architect-delegation` skill** (auto-discovered) — explains when planning work can be delegated and what remains off-limits to the architect.
- **`delegate-to-devin` skill** (auto-discovered) — optional mechanics for firing a Devin session during research when the helper is configured.

## Archived

Under `archive/` and not installed by `on_poll`:

- `commands/multiagent-task.md` — supervisor + per-stage delegation flow.
- `skills/delegate-to-claude/` and `skills/delegate-to-codex/` — used by the old supervisor to delegate execute / review / planning stages to specialised sub-agents.

The orchestrator's non-workflow `TASK_SKILL` escape hatch is retained — anyone wanting to revive the multi-agent flow can move files back out of `archive/` and set `TASK_SKILL=multiagent-task`.

## Open TODOs

- **`review-pr --reviewer codex|cursor|gemini`** — currently stubbed. Wire up real dispatch.
- **Parallel reviewers** — let `review-pr` spawn multiple models simultaneously, each writing findings with its own tag.
