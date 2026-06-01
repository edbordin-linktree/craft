# Plugins

Plugins extend craft with optional integrations for notifications, CI, and other external services.

## How It Works

Each plugin lives in its own directory under `plugins/`. All files are optional;
use only the pieces the plugin needs:

- **`plugin.conf`** — configuration variables and metadata such as `DEPENDS_ON`
  or `QUEUE_STATES`
- **`hooks.sh`** — shell functions named after lifecycle hooks
- **`project/`** — optional project assets to symlink into enabled projects
- **`skills/`** — optional agent skills to install into enabled projects
- **`scripts/`** — optional plugin helper scripts

The `run-hook.sh` dispatcher is called by Craft at lifecycle moments. If an enabled plugin has `hooks.sh`, Craft sources it and invokes the matching function if it exists. Plugins without hooks are valid.

## Project Assets

If an enabled plugin has a `project/` directory, Craft syncs every file and symlink in that tree into the project root:

- `craft plugin add <project> <plugin>`
- `craft plugin check <project>`
- every orchestrator poll, before `on_poll`

Assets are always symlinked. Craft creates parent directories as needed, replaces an existing symlink that already points into the same plugin asset tree, and refuses to overwrite a real project file or an unrelated symlink.

Common `project/` asset paths:

- `project/.claude/commands/*.md`

Plugins should keep project assets generic and avoid writing project-specific local state into `project/`.

Agent skills should live at `plugins/<plugin>/skills/<skill-name>/SKILL.md`.
Craft installs each enabled plugin skill into both `.claude/skills/` and
`.codex/skills/`. Skill names must be unique across the enabled plugin set.

## Workflow Runtime

Craft core exposes a small stage-based runtime for task workflows. The stock `standard-pr` happy path is:

```text
implement -> qa -> pr_review -> complete
```

Context loading and worktree setup are executor/orchestrator responsibilities, not workflow stages. `blocked` is an explicit terminal escape, not part of happy-path `advance`.

Use `craft task stage ...` to mutate stages. These commands update the task file's YAML frontmatter (`stage:`, `stage_status:`, and `stage_reason:`), dispatch stage lifecycle hooks, and publish a `stage.changed` event; callers should not invoke stage hooks directly.

```bash
craft task stage get task-123
craft task stage set task-123 implement --reason "starting code changes"
craft task stage advance task-123 --reason "QA passed"
craft task stage block task-123 --reason "dependency unavailable"
craft task stage complete task-123
```

Task agents also get a task-scoped runtime directory under `tasks/<task-id>/.orchestrator/` for events and surface registry state. cmux task workspace identity is not serialized there: Craft resolves workspaces by hidden cmux metadata (`craft:project-id`, `craft:task-id`, and related keys) whenever a helper needs to address the task workspace.

The default workflow preset is core-bundled at `workflows/standard-pr/`. Tasks without `workflow:` use `standard-pr`. Enabled plugins can also contribute workflow presets under `plugins/<plugin>/workflows/<workflow>/workflow.conf`. Workflow presets can set default `AGENT` and `AGENT_MODEL`; task frontmatter `agent:` and `agent_model:` override those defaults. Tasks with `skill:` bypass workflow rendering and keep the legacy direct command dispatch behavior; prefer a dedicated `workflow:` plus agent defaults for new variants.

Use `workflow:` for task behavior and `agent:` / `agent_model:` for execution defaults or overrides.

Workflow prompt fragments and deterministic hooks are deliberately separate:

- Prompt fragments tell the agent what to do.
- Script hooks do side effects such as opening surfaces, starting watchers, or notifying external systems.

Plugins can append prompt text to a stage by adding:

```text
plugins/<plugin>/fragments/stages/<stage>.md
```

Fragments concatenate after the stage's base prompt in `PLUGINS` order.

Plugins can also contribute a stage by adding a stage file:

```text
plugins/<plugin>/stages/watching_prod_deploy.md
```

The stage file's frontmatter declares placement:

```yaml
---
insert: after:pr_review
events: buildkite.build_ready
queue_state: waiting
---
```

`queue_state:` is optional. When present, entering that stage projects the task into the named `queue/<state>/` folder without changing the stage again. Stage and event IDs come from filenames. `stages/qa.md` defines `qa`; `plugins/buildkite/fragments/stages/qa.md` extends it. Event definitions live in `events/<event>.md` or `plugins/<plugin>/events/<event>.md`, with fragments in `plugins/<plugin>/fragments/events/<event>.md`.

Workflow-owned plugin stages that are not inserted into `standard-pr` should declare their owning workflow instead of `insert`, for example:

```yaml
---
workflow: discovery
queue_state: in-progress
---
```

The `planning` plugin uses this shape for discovery work. Choose it directly in task frontmatter with `workflow: discovery`; its workflow config provides the default discovery agent/model, and normal per-task `agent:` and `agent_model:` fields can override them. The orchestrator launches it through the regular task workspace and semantic `agent` surface.

The supported agent wake-up path is a pending-only typed event queue:

```bash
craft event enqueue task-123 --type pr_review --summary "new review thread" --json payload.json
craft event counts task-123
craft event list task-123 --type pr_review --limit 5
craft event take task-123 --type pr_review --limit 5
craft event ack task-123 --publisher noisy-helper --before 2026-06-01T00:00:00Z
```

Inside a task workspace, the task id can be omitted because `craft task run` and
`craft task resume` export `CRAFT_TASK_ID` and the event CLI can also infer the
task from `tasks/<task-id>/`:

```bash
craft event counts --type review_comment
craft event list --publisher babysit-pr --limit 10
craft event take --type ci_status --limit 5
craft event ack --type pr_approval
```

All filtered event commands accept the same filter flags: `--id`, repeatable
`--type`, repeatable `--publisher`, repeatable `--summary-contains`,
`--since`, and `--before`. `list`, `take`, and `ack` also accept `--limit`.
`list` is read-only, `take` returns matching events and deletes them, and
`ack` deletes matching events without printing payloads.

Each enqueue writes one JSON item under `.orchestrator/events/pending/`. When
the queue transitions from zero matching notification-filtered events to one or
more, Craft injects a short task-targeted message such as
`CRAFT_EVENTS task=task-123 pending=3 counts=pr_review:2,ci_status:1`.
Event bodies stay on disk until returned by `craft event take` or deleted by
`craft event ack`. The orchestrator also re-sends this wake-up if matching
pending events remain unconsumed for 15 minutes, so agents can either consume
the events or narrow their task notification filter.

Tasks can narrow which pending events trigger wake-up messages without dropping
or muting event storage:

```bash
craft event notify-filter set --type review_comment --type ci_status
craft event notify-filter get
craft event notify-filter clear
```

Notification filters support the non-time event filters: repeatable `--type`,
repeatable `--publisher`, and repeatable `--summary-contains`. Notification
counts reflect only matching pending events.

Long-running tool-style plugins should publish back into the same queue instead
of asking the task agent to poll. For example, the `devin` plugin records
pending Devin sessions under the task directory, checks them from `on_poll`,
and wakes the task with `devin.session_settled` or `devin.session_failed` when
there is a result to consume.

Generic web surfaces are keyed by stable semantic ids such as `github-pr`, `diffhub-review`, or `buildkite-status`. Under cmux, Craft stores that semantic id and related attributes on the cmux surface metadata, then resolves the current surface ref with the mux provider when focusing or closing. `craft surface open` creates or reuses a browser surface in the task workspace; `craft surface focus` returns `surface_not_found` when no surface metadata matches; `craft surface close` closes the matched surface when present.

## Queue States

Plugins may declare extra queue states in `plugin.conf`:

```bash
QUEUE_STATES=local-review,custom-review
```

Craft always provides the core states `drafts`, `pending`, `approved`, `in-progress`, `waiting`, `done`, `blocked`, and `archive`. Plugin states are created under `queue/`, included in orchestrator counts and milestone scans, and rendered generically in the terminal dashboard.

## Dependencies

Plugins may declare direct dependencies in `plugin.conf`:

```bash
DEPENDS_ON=local-review
```

`craft plugin add` enables dependencies before the requested plugin. `craft plugin check`, project asset sync, and hook dispatch all validate the dependency list; a plugin with missing dependencies is reported and its hooks are skipped.

## Event Hooks

Plugins can observe published events with `on_event`. The default behavior is pass-through: Craft queues the event after hooks run.

Within `on_event`, plugins can call:

```bash
event_consume
event_publish local_review.comment payload.json --publisher diffhub --summary "new local review comment"
```

`event_consume` prevents the original event from being queued. `event_publish` republishes a canonical event through `craft event enqueue`, including a publisher name so plugins can avoid consuming their own events.

## Enabling Plugins

In `craft.conf`, set the `PLUGINS` variable to a comma-separated list:

```bash
PLUGINS=slack-daily-thread
```

Then configure the plugin by editing its `plugin.conf` if it has one.

### Linear CLI

The `linear-sync` plugin expects `schpet/linear-cli`, which installs a binary
named `linear`.

```bash
brew install schpet/tap/linear
linear auth login
```

On Linux hosts without Homebrew or sudo, install the matching release tarball
into `~/.local/bin`; see `plugins/linear-sync/plugin.conf` for the exact
commands. Do not use the npm package named `linear`, which is unrelated.

## Available Hooks

| Hook | When | Arguments |
|---|---|---|
| `on_poll` | Each orchestrator poll cycle | `--project-dir PATH` |
| `on_started` | Task started (moved to in-progress) | `--project-dir PATH --task-id ID --task-file PATH --task-dir PATH` |
| `on_waiting` | Task moved to waiting (PR created) | `--project-dir PATH --task-id ID --task-file PATH --task-dir PATH --pr-url URL` |
| `on_ready` | PR marked as ready (draft → ready) | `--project-dir PATH --pr-url URL --pr-number N --pr-title TITLE` |
| `on_done` | Task completed (PR merged) | `--project-dir PATH --task-id ID --task-file PATH --task-dir PATH --pr-url URL` |
| `on_blocked` | Task blocked | `--project-dir PATH --task-id ID --task-file PATH --task-dir PATH --reason REASON` |
| `on_milestone` | All tasks in a milestone completed | `--project-dir PATH --milestone ID` |
| `on_stage_end` | Before Craft leaves the previous task stage | `--project-dir PATH --stage PREVIOUS --next-stage NEXT --task-id ID --task-file PATH --task-dir PATH --status STATUS --reason REASON --workflow NAME --workflow-options-json JSON` |
| `on_stage_start` | After Craft enters the new task stage | `--project-dir PATH --stage STAGE --previous-stage PREVIOUS --task-id ID --task-file PATH --task-dir PATH --status STATUS --reason REASON --workflow NAME --workflow-options-json JSON` |
| `on_stage_resume` | After Craft recreates a missing task agent surface without changing stage | `--project-dir PATH --stage STAGE --task-id ID --task-file PATH --task-dir PATH --status STATUS --reason REASON --workflow NAME --workflow-options-json JSON` |

Task-related hooks include `--task-file`, `--task-dir`, and `--pr-url` when Craft can derive them from the queue file and project layout. Hook handlers should ignore unknown arguments so this contract can grow without breaking existing plugins.

## Creating a Plugin

1. Create a directory: `plugins/my-plugin/`
2. Add only the files it needs: `hooks.sh`, `plugin.conf`, `project/`, `skills/`, or `scripts/`
3. Enable it in `craft.conf`: `PLUGINS=my-plugin`

Hooks run in subshells — plugins can't interfere with each other or the main process.
