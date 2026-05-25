# craft-bk-status

Tiny Buildkite build viewer. Built because cmux's in-app browser can't
complete the Okta SSO flow that Buildkite's web UI requires — so we shell out
to the `bk` CLI (which uses a long-lived API token) and render the response
ourselves.

## Stack

Same as the dashboard:

- Bun runtime (`.tsx` natively, no build)
- `Bun.serve` + Preact server-render
- htmx for the 5s status refresh
- No client framework, no bundler, no auth (loopback-only)

## Run manually

```bash
cd plugins/buildkite-status/bk-status
bun install
bun start --port 27435
```

Open `http://127.0.0.1:27435/build/<org>/<pipeline>/<number>` for a specific
build, or `http://127.0.0.1:27435/by-pr?url=<github-pr-url>` to resolve via
`gh pr checks`.

## Run via the orchestrator helper

The expected entry point is the helper script:

```bash
"$CRAFT_ROOT/plugins/buildkite-status/scripts/show-build-status" <pr-url>
```

That:
1. Ensures the bk-status server is up through Craft's background helper.
2. Resolves the PR's Buildkite check link via `gh pr checks`.
3. Opens a cmux browser surface to the right of the caller's pane, labelled
   `bk:<pipeline>#<number>`.

Designed to be called from the babysit-pr loop in `work-task.md` once the PR
has been merged and a Buildkite check is detected — the operator wants to
watch the deploy without flipping back to a Buildkite tab they can't log
into anyway.

## Routes

| Method | Path                                | Behaviour                                 |
| ------ | ----------------------------------- | ----------------------------------------- |
| GET    | `/`                                 | Index / direct-link instructions          |
| GET    | `/build/:org/:pipeline/:number`     | Render one build + htmx tick every 5s     |
| GET    | `/tick/:org/:pipeline/:number`      | Inner status table (htmx swap target)     |
| GET    | `/by-pr?url=<pr-url>`               | Resolve PR's BK check → 302 to `/build/…` |
| GET    | `/healthz`                          | `ok`                                      |

## What it currently shows

- Build state, branch, short commit, creator
- Jobs table (step_key, name, state pill, duration)
- "Triggered builds" panel — every job that fired a downstream pipeline,
  with a click-through to that downstream build on this same server
- A direct "open in Buildkite ↗" link (works in your system browser; broken
  in cmux until your IT lifts the SSO block)

## Future work

- `bk job logs` integration for live job log streaming
- Annotations / artifacts panel (Buildkite uploads markdown annotations from
  builds — those are usually the most useful "what happened" surface)
- Multi-build watch (list view of recent builds across pipelines)
- WebSocket / SSE push instead of htmx 5s poll (cheap optimisation, the
  `bk` CLI already supports `bk build watch`)
- Auth: switch to mutual TLS or a simple token if we ever want to expose it
  off-loopback
