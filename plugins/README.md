# Plugins

Plugins extend craft with optional integrations for notifications, CI, and other external services.

## How It Works

Each plugin lives in its own directory under `plugins/` and provides:

- **`plugin.conf`** — configuration variables (channels, paths, tokens, etc.)
- **`hooks.sh`** — shell functions named after lifecycle hooks

The `run-hook.sh` dispatcher is called by agent skills at key lifecycle moments. It sources each enabled plugin's `hooks.sh` and invokes the matching function if it exists.

## Enabling Plugins

In `craft.conf`, set the `PLUGINS` variable to a comma-separated list:

```bash
PLUGINS=slack-daily-thread
```

Then configure the plugin by editing its `plugin.conf`.

## Available Hooks

| Hook | When | Arguments |
|---|---|---|
| `on_poll` | Each orchestrator poll cycle | *(none)* |
| `on_started` | Task started (moved to in-progress) | `--task-id ID` |
| `on_waiting` | Task moved to waiting (PR created) | `--task-id ID --pr-url URL` |
| `on_ready` | PR marked as ready (draft → ready) | `--pr-url URL --pr-number N --pr-title TITLE` |
| `on_done` | Task completed (PR merged) | `--task-id ID --pr-url URL` |
| `on_blocked` | Task blocked | `--task-id ID --reason REASON` |
| `on_milestone` | All tasks in a milestone completed | `--milestone ID` |

## Creating a Plugin

1. Create a directory: `plugins/my-plugin/`
2. Add `plugin.conf` with any required configuration
3. Add `hooks.sh` implementing the hooks you need
4. Enable it in `craft.conf`: `PLUGINS=my-plugin`

Hooks run in subshells — plugins can't interfere with each other or the main process.
