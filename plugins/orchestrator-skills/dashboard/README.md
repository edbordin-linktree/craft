# craft-dashboard

A lightweight web UI for the craft orchestrator. Renders the queue as a
column-per-status layout (TUI-inspired) with clickable links that focus the
relevant cmux surface — task terminal, or diffhub browser tab for
diffhub-review tasks.

## Stack

- **Bun** (runs `.tsx` natively, no build step, sub-50ms startup)
- **Bun.serve** (built-in HTTP, no framework)
- **Preact** + `preact-render-to-string` (server-rendered JSX)
- **htmx** (CDN script tag; click → POST + 3s auto-refresh)
- **gray-matter** (task YAML frontmatter)
- **chokidar** (file watching → in-memory snapshot refresh)

## Install Bun (one-time)

```bash
brew install oven-sh/bun/bun
```

## Run

```bash
cd plugins/orchestrator-skills/dashboard
bun install
bun start --project /Users/ed/tasks/custom-orchestrator/craft/projects/llm-classification
```

Then open `http://127.0.0.1:27434`.

When the plugin is installed, `DASHBOARD_CMD` in `craft.conf` is the supported
entrypoint. Craft starts the command and focuses the configured dashboard
surface; the dashboard code itself does not create cmux panes.

## How it works

1. **Queue scan** (`queue.ts`) — reads `queue/<state>/*.md`, parses
   frontmatter with gray-matter, extracts Linear ticket refs (`TRU-\d+`,
   `LIN-\d+`, `ENG-\d+`) from the body, and pulls the last work-log heading
   so the dashboard can show "↳ last activity".
2. **In-memory snapshot** (`server.tsx`) — `scanProject(dir)` runs at startup
   and on every chokidar event under `queue/` or `tasks/`. The dashboard
   re-renders from the snapshot on every `/` request; htmx polls every 3s
   for fresh markup.
3. **Cmux focus** (`cmux.ts`):
   - Task surface: finds the task terminal by tab title in the task workspace.
     Falls back to `cmux select-workspace` if the surface is missing.
   - Diffhub and PR surfaces: focus Craft-registered stable surface IDs
     (`diffhub-review`, `github-pr`) through `craft-mux focus`.

## Routes

| Method | Path                 | Behavior                                      |
| ------ | -------------------- | --------------------------------------------- |
| GET    | `/`                  | Render the dashboard (HTML)                   |
| GET    | `/healthz`           | Plain `ok` for liveness checks                |
| GET    | `/snapshot.json`     | `{snapshotTs, taskCount}` (lightweight poll)  |
| POST   | `/focus/task/:id`    | Focus the agent surface in cmux               |
| POST   | `/focus/diffhub/:id` | Focus the diffhub browser surface in cmux     |
| POST   | `/ready/:id`         | Send a `ready_for_pr` event via `craft task signal` |

Binds to `127.0.0.1` by default. Pass `--host 0.0.0.0` to expose, but you
probably don't want that — `cmux` calls happen on the host the dashboard runs
on.

## Configuration

- `LINEAR_ORG` env var — Linear org slug for the `linear.app/<org>/issue/...`
  links. Defaults to `linktreebio`.

## Vendored Diffhub

The orchestrator-skills plugin runs the local-review UI from
`$CRAFT_ROOT/vendor/diffhub` when that checkout exists. This keeps every craft
project on the same forked diffhub binary and avoids per-task `diffhub-source`
setup. The fork is updated manually:

```bash
cd $CRAFT_ROOT/vendor/diffhub
git pull
```

`DIFFHUB_SOURCE_DIR` still overrides the vendored checkout for local testing.

## Future work (intentionally not in v1)

- Stream `logs/orchestrator.log` tail into a side panel.
- Authentication (currently relies on loopback-only binding).
- Multi-project view.
