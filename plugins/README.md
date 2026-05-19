# Plugins

Plugins extend craft with optional integrations for notifications, CI, and other external services.

## How It Works

Each plugin lives in its own directory under `plugins/` and provides:

- **`plugin.conf`** — configuration variables (channels, paths, tokens, etc.)
- **`hooks.sh`** — shell functions named after lifecycle hooks
- **`project/`** — optional project assets to symlink into enabled projects

The `run-hook.sh` dispatcher is called by agent skills at key lifecycle moments. It sources each enabled plugin's `hooks.sh` and invokes the matching function if it exists.

## Project Assets

If an enabled plugin has a `project/` directory, Craft syncs every file and symlink in that tree into the project root:

- `craft plugin add <project> <plugin>`
- `craft plugin check <project>`
- every orchestrator poll, before `on_poll`

Assets are always symlinked. Craft creates parent directories as needed, replaces an existing symlink that already points into the same plugin asset tree, and refuses to overwrite a real project file or an unrelated symlink.

Common asset paths:

- `project/.claude/commands/*.md`
- `project/.claude/skills/*`
- `project/.codex/skills/*`

Plugins should keep project assets generic and avoid writing project-specific local state into `project/`.

## Queue States

Plugins may declare extra queue states in `plugin.conf`:

```bash
QUEUE_STATES=diffhub-review,custom-review
```

Craft always provides the core states `pending`, `approved`, `in-progress`, `waiting`, `done`, `blocked`, and `archive`. Plugin states are created under `queue/`, included in orchestrator counts and milestone scans, and rendered generically in the terminal dashboard.

## Enabling Plugins

In `craft.conf`, set the `PLUGINS` variable to a comma-separated list:

```bash
PLUGINS=slack-daily-thread
```

Then configure the plugin by editing its `plugin.conf`.

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

Task-related hooks include `--task-file`, `--task-dir`, and `--pr-url` when Craft can derive them from the queue file and project layout. Hook handlers should ignore unknown arguments so this contract can grow without breaking existing plugins.

## Creating a Plugin

1. Create a directory: `plugins/my-plugin/`
2. Add `plugin.conf` with any required configuration
3. Add `hooks.sh` implementing the hooks you need
4. Enable it in `craft.conf`: `PLUGINS=my-plugin`

Hooks run in subshells — plugins can't interfere with each other or the main process.
