# cmux Integration Notes

Craft treats mux surfaces as semantic handles. Callers should ask the mux
backend for a surface such as `agent`, `github-pr`, `diffhub-review`, or
`buildkite-status`; they should not depend on cmux tab titles or surface refs.

For cmux, the backend stores workspace identity in hidden metadata:

- `craft:schema-version`
- `craft:project-id`
- `craft:project-dir`
- `craft:task-id` and `craft:task-dir` for task workspaces

Semantic surfaces are stored as `craft:surface:<name>` metadata values. The
value includes the opaque cmux `surface_id`, `type`, `purpose`, optional
`title`, `url`, `agent`, `placement`, and `updated_at`.

The cmux backend currently supports two placement values: `left` and `right`.
The `agent` surface defaults to `left`; every other semantic surface defaults
to `right`. The left agent adopts the existing terminal surface in a new task
workspace. Right-side surfaces reuse an existing right pane as tabs. If no
right pane exists, the backend creates one right pane and then appends future
right-side surfaces as tabs instead of splitting repeatedly.

Detached-safe cmux operations are kept inside `bin/lib/mux-cmux.sh`: metadata
lookup/get/set/clear, tree reads, terminal/browser surface creation, terminal
send/send-key, known-surface close, and workspace/surface rename. Visible
status banners still use `set-status`, `clear-status`, and `list-status`, but
status is display state only and must not be used as identity.

Metadata lookup prefers cmux workspace UUIDs over short refs when both are
available. Remote snapshot commands compare against UUIDs, while attached UI
commands can still accept short refs.

Remote validation notes from the `local/remote-workspace-snapshots` fork:

- Remote task workspace creation uses `cmux ssh <same-host> --cwd <task-dir>
  --name <title> --json` from a remote orchestrator/supervisor workspace. When
  the Swift UI relay is attached this creates a normal visible remote
  workspace; when it is unavailable cmux creates a detached same-host workspace
  snapshot directly on the remote daemon.
- `new-workspace` remains a generic UI workspace command. Craft must not use it
  for remote task workspace creation.
- `new-pane --direction right` creates the first right-side pane correctly in
  remote snapshots. `new-split right` can appear as a same-pane tab in the
  snapshot tree, so Craft does not use it for the first right-side pane.
- Same-workspace remote snapshot mutation works when commands target the
  workspace UUID.
- Cross-workspace target routing should use the target workspace UUID, not a
  short `workspace:N` ref. Current remote snapshot builds route explicit
  target UUIDs to the target daemon slot and bypass the caller Swift relay for
  known detached targets.
- Remote smoke from an attached orchestrator workspace confirmed Craft creates
  task workspaces through `cmux ssh` and records task metadata on the resulting
  remote workspace. Craft no longer writes task-session workspace mappings;
  helpers resolve task workspaces from cmux metadata on demand.
- Detached fallback smoke confirmed `cmux ssh <same-host> --cwd ... --json`
  creates detached task snapshots, then metadata writes, tree reads, terminal
  sends, browser surface creation, status set/list, and cleanup work against
  the new task snapshot.
- Remote wrapper status routing works for detached targets as of cmux
  `c5864cac7`. `set-status`/`list-status` are still display-only state, not
  identity.
- High-contention detached snapshot mutation passed against cmux `733c7e4d3`.
  A 20-way remote-wrapper stress run against one detached workspace completed
  with all metadata/status entries present and no stderr output.

UI operations are best-effort only. `select-workspace`, `focus-surface`,
window movement, and browser navigation after creation require a live Swift UI
relay. Supervisor loops must not depend on them. Dashboard focus actions resolve
identity through detached-safe metadata/tree calls first, then attempt focus; if
the cmux UI relay is unavailable the dashboard returns `cmux_ui_unavailable`
without treating it as a task failure.

Direct cmux calls outside `bin/lib/mux-cmux.sh` should be rare. Current allowed
exceptions are:

- `plugins/craft-dashboard/dashboard/cmux.ts`, which performs user-requested
  UI focus/select actions and status reads for dashboard display. It reports UI
  relay failure gracefully as `cmux_ui_unavailable`.
- `bin/craft` doctor-style dependency and plugin diagnostics. For cmux it only
  checks whether a `cmux` binary is present and does not mutate workspaces.
- User-facing cmux documentation under `plugins/cmux-tools`, which describes
  the cmux CLI rather than Craft's provider boundary.
