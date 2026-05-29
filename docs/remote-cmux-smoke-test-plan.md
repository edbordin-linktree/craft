# Remote cmux Craft Smoke Test Plan

This plan validates Craft against the remote cmux model where the caller workspace and target workspace may each be attached to the Swift UI or detached/headless on the remote host.

## Purpose

Set up a bare-bones Craft project on the remote host and exercise the orchestrator, plugin system, events, fragments, skills injection, semantic surfaces, status banners, and dashboard UI-only paths through the cmux provider layer.

The test harness should run from inside a real remote cmux orchestrator workspace so command behavior matches a human using this environment later.

## Current Verification Notes

Last updated: 2026-05-29.

Validated against `CMUX_TAG=craft_integration` with cmux `0.64.10 (90) [733c7e4d3]`:

- Attached remote caller -> attached Craft target: passed for project/task metadata lookup, semantic agent/helper/browser surfaces, right-pane browser placement, status banners, event enqueue/counts, and plugin workflow fragments.
- Attached remote caller -> forced detached target: passed for lowercase detached workspace lookup, terminal send, browser surface create/tree/metadata validation, status set/list, and metadata cleanup.
- Detached caller -> detached target: passed for Craft provider metadata lookup, terminal send, browser surface create/tree/metadata validation, and close cleanup.
- Detached caller -> attached target: passed for metadata lookup, terminal send, browser surface create/metadata validation, and close cleanup. Attached target workspace IDs may still appear as Swift uppercase UUIDs; command routing worked.
- Detached status routing: passed after cmux `c5864cac7`. Remote wrapper `set-status`/`list-status` against a detached workspace UUID worked, and Mac tagged CLI `list-status`/`set-status`/`list-status` against the same detached UUID showed both remote and Mac entries.
- Bounded remote orchestrator smoke: passed. The task moved into `queue/in-progress`, the task workspace was resolved by cmux workspace metadata, and the agent surface was resolved by cmux surface metadata.
- Idempotency smoke: passed. Repeated `ensure_task_session`, agent surface ensure, and browser surface ensure converged on the same task workspace and semantic surfaces; closing the browser cleared its metadata.
- Dashboard UI behavior: passed. A fake relay failure returned a non-fatal `cmux_ui_unavailable`, and a real attached focus call resolved task metadata then focused the recorded agent surface.
- Detached snapshot locking/contention: passed against cmux `733c7e4d3`. A 20-way remote-wrapper stress run against one detached workspace completed with `failures=0`, `meta_ok=20`, `status_ok=20`, and `err_lines=0`.
- Local regression suites passed: `test/test-queue.sh`, `test/test-plugins.sh`, `test/test-workflow.sh`, `test/test-runtime.sh`, `test/test-orchestrator-runtime.sh`, and dashboard `bun x tsc --noEmit`.
- Doctor/plugin diagnostics: `craft doctor [project]` now validates enabled plugin directories, `DEPENDS_ON` relationships, and plugin `check_deps` hooks without syncing assets or creating mux surfaces. Covered by `test/test-plugins.sh`.
- Raw cmux audit: plugin helpers route through `craft-mux` or task-runtime surface helpers. Remaining direct cmux usage is documented in `docs/cmux-integration.md`.

Keep using this plan as the verification checklist. Clean the `craft_integration` dev app back to only `workspace:1` after each smoke run.

## Phase 0: Harness Setup

- Create a disposable remote project, for example `~/craft-remote-smoke`.
- Include the smallest useful `craft.conf`, `tasks/`, and plugin setup.
- Configure Craft for cmux:
  - `MULTIPLEXER=cmux`
  - `DEFAULT_AGENT=codex`
  - `ARCHITECT_AGENT=codex`
- Run the smoke harness from an actual remote cmux orchestrator terminal.
- Support a `--keep-open` mode so the resulting workspace can be inspected visually before cleanup.

cmux dev targeting signpost:

- Build and launch the fork with the `craft_integration` tag from the cmux repo:
  - `CMUX_SKIP_ZIG_BUILD=1 ./scripts/reload.sh --tag craft_integration --launch`
- Drive the fork only through the tag-bound CLI:
  - `CMUX_TAG=craft_integration scripts/cmux-debug-cli.sh ...`
- The tagged fork uses the Swift app socket:
  - `/tmp/cmux-debug-craft-integration.sock`
- Do not use the default `cmux` on the Mac for this smoke run; that may target `/Applications/cmux.app` release.
- Do not use `/tmp/cmux-cli`; it points at the most recently reloaded dev build, not necessarily the `craft_integration` build.
- The remote `~/.cmux/bin/cmux` wrapper is valid inside a terminal created by the tagged dev app because the shell env supplies:
  - `CMUX_SOCKET_PATH`
  - `CMUX_WORKSPACE_ID`
  - `CMUX_SURFACE_ID`
  - `CMUX_REMOTE_DAEMON_SLOT`
  - `CMUX_BUNDLED_CLI_PATH`
- Outside an attached remote cmux shell, avoid the remote wrapper fallback unless the test intentionally covers detached/headless behavior.

Success criteria:

- The harness can create and remove its remote project without touching unrelated task folders.
- The orchestrator runs inside the cmux orchestrator workspace.
- The harness records workspace IDs, surface IDs, and relevant metadata for later assertions.

## Phase 1: Core Orchestrator

Exercise the basic Craft orchestrator flow.

- Start Craft in the remote smoke project.
- Ensure the project/orchestrator workspace exists.
- Verify project workspace metadata:
  - `craft:schema-version=1`
  - `craft:project-id`
  - `craft:project-dir`
- Create or discover one simple task.
- Move the task into an active state.
- Create the task workspace using the cmux provider task-workspace primitive, which should call remote `cmux ssh <same-host> --cwd <task-dir> --name <title> --json`.
- Verify task workspace metadata:
  - `craft:schema-version=1`
  - `craft:project-id`
  - `craft:project-dir`
  - `craft:task-id`
  - `craft:task-dir`
- Verify the main agent surface has `craft:semantic=agent` surface metadata.

Success criteria:

- No title-prefix lookup is required for project or task workspace identity.
- Task workspace creation works from the remote environment.
- The agent surface can be resolved from metadata and validated against `cmux tree`.

## Phase 2: Task Workspace Matrix

Run the caller/target workspace matrix:

- Attached caller, attached target.
- Attached caller, detached target.
- Detached caller, attached target.
- Detached caller, detached target.

For each case:

- Resolve the target workspace by metadata.
- Validate the target with `cmux tree`.
- Ensure the agent terminal surface exists.
- Ensure one non-agent semantic surface exists, such as a browser with `craft:semantic=smoke-browser`.
- Use placement semantics:
  - assume the agent is on the left;
  - place all other semantic surfaces on the right;
  - if the right pane already exists, append a tab instead of splitting again.
- Record and read surface metadata containing at least:
  - `surface_id`
  - `type`
  - `purpose`
  - optional `title`, `url`, `agent`, `updated_at`
- Send text and a common key to the terminal surface.
- Close the non-agent surface and clear its metadata.

Extra case:

- From an attached caller, run `cmux ssh --detached <same-host> --cwd <task-dir> --name <title> --json`.
- Verify it creates a detached target even though a Swift relay is available.
- Mutate that detached target explicitly and confirm the command does not route through the caller Swift socket.

Success criteria:

- All detached-safe provider operations work in every caller/target combination where cmux supports the target.
- UI-only operations are not retried from supervisor loops.
- Closing a surface removes the recorded semantic surface metadata.

## Phase 3: Plugin Hooks

Create a minimal smoke plugin that logs hook invocations to JSONL.

Exercise:

- install/setup hook behavior if supported;
- task state before/after hooks;
- stage start/end hooks;
- queue or event hooks where supported;
- plugin helper commands that call through `craft-mux`.

Success criteria:

- Hook ordering is deterministic enough for the documented contract.
- Hook arguments include the expected task and project context.
- A failing smoke hook is isolated and reported without corrupting orchestrator state.
- Plugin helper calls do not shell out to raw cmux directly.

## Phase 4: Events System

Use the smoke plugin or a test script to publish and consume events.

Exercise:

- enqueue and consume an event;
- payload propagation;
- duplicate suppression or idempotency behavior, if expected by the event system;
- orchestrator wakeup behavior;
- restart persistence;
- consumed events not replaying unexpectedly.

Success criteria:

- Events survive orchestrator restart where they are meant to.
- Consumed events do not trigger duplicate work.
- Event-driven plugin behavior can create or update semantic surfaces through the provider.

## Phase 5: Fragments And Skills Injection

Add small smoke fragments and one smoke skill.

Exercise:

- project-level fragments;
- plugin-provided fragments;
- task/context fragments;
- skills injection into the generated prompt or agent context;
- removal or update of a fragment between runs.

Success criteria:

- The rendered agent input includes the expected fragments and skill content.
- Fragment ordering matches Craft's documented or existing behavior.
- Updated or removed fragments do not leave stale prompt text behind.

## Phase 6: Surface Provider API

Exercise the high-level provider abstraction rather than raw cmux command shapes.

Examples:

- ensure terminal surface;
- ensure browser surface;
- check surface existence;
- send text/key to terminal surface;
- close surface;
- rename workspace or surface;
- read and update semantic surface metadata.

Success criteria:

- Task panes and named panes use the same semantic-surface path.
- The main task agent is just the surface with `craft:semantic=agent`.
- Plugin surfaces use semantic values such as `buildkite-status`, `diffhub-review`, or `devin-session` stored in `craft:semantic` surface metadata.
- Direct cmux shell-outs outside the provider are either gone or documented as UI-only/direct exceptions.

## Phase 7: Doctor And Plugin Diagnostics

Revive or adapt the old `craft doctor` behavior so plugins can contribute environment and runtime checks.

Exercise:

- core Craft checks for required commands, config, project layout, task directories, and mux backend availability;
- cmux provider checks for workspace metadata lookup, metadata set/get/list/clear, tree access, terminal send support, browser surface support, status banner support, and UI relay availability;
- plugin-provided doctor hooks for plugin-specific commands, credentials, config files, background services, and surface dependencies;
- machine-readable output suitable for tests and dashboard display;
- human-readable output suitable for CLI troubleshooting.

Success criteria:

- A clean smoke project reports all required core and plugin checks as passing.
- Missing optional plugin dependencies produce warnings instead of hard failures.
- Missing required plugin dependencies produce actionable failures with the plugin name and check ID.
- cmux UI-only checks report relay availability separately from detached-safe command health.
- Doctor hooks do not mutate workspaces or create surfaces unless a hook explicitly declares a repair mode.

## Phase 8: Dashboard And UI-Only Behavior

Exercise dashboard actions that require the Swift UI relay.

Attached behavior:

- show terminal;
- focus/select workspace;
- open task workspace;
- attach to a remote workspace if needed;
- retry focus/select once after attach.

Detached or relay-unavailable behavior:

- resolve workspace/surface through metadata and tree where possible;
- return a non-fatal `cmux_ui_unavailable` style response for focus/select/attach failures;
- avoid background retry loops for UI focus/attach.

Success criteria:

- Attached UI actions work when the relay is available.
- Detached/headless mode degrades gracefully and does not mark the task failed just because focus is unavailable.

## Phase 9: Status Banners

Exercise visible operator feedback without using status as identity.

- Set a task status banner.
- List status banners.
- Clear the task status banner.
- Detach and attach around status updates where practical.

Success criteria:

- Status banners reflect operator state.
- Workspace and surface lookup never depends on status text.
- Status cleanup is idempotent.

## Phase 10: Restart And Idempotency

Restart the orchestrator and rerun the same smoke flow.

Verify:

- project workspace is reused by metadata;
- task workspace is reused by metadata;
- semantic surfaces are reused when still present;
- stale surface metadata is detected when `cmux tree` no longer contains the recorded surface;
- no duplicate browser or agent surfaces are created;
- runtime files and cmux metadata reconcile to the same workspace/surface IDs.

Success criteria:

- Repeated runs converge to one project workspace, one task workspace per task, and one surface per semantic key unless the test intentionally creates additional tabs.

## Phase 11: Concurrency And Locking

Exercise detached snapshot mutation under light contention.

- Run multiple metadata writes to the same detached workspace.
- Create and close different semantic surfaces in close succession.
- Set and clear status banners in close succession.
- Inspect resulting snapshot/tree state.

Success criteria:

- Snapshot locking prevents corrupt JSON or partial state.
- Lock wait failures, if any, are explicit and actionable.
- Retrying an idempotent provider operation repairs the state.

## Phase 12: Cleanup

Clean up after every smoke run unless `--keep-open` is set.

- Close attached demo workspaces.
- Clear detached snapshots created by the test.
- Remove disposable remote project directories.
- Leave the cmux dev instance with only the one default local workspace.

Success criteria:

- `cmux tree` no longer shows smoke workspaces.
- Detached snapshot count for smoke workspaces is zero.
- The remote host has no leftover `~/craft-remote-smoke*` directories unless explicitly kept.

## Suggested Automation Shape

Add a smoke runner with a command shape like:

```sh
scripts/remote-cmux-smoke \
  --host ed@tdb \
  --project-dir ~/craft-remote-smoke \
  --phase all \
  [--keep-open]
```

Useful phase selectors:

- `setup`
- `orchestrator`
- `matrix`
- `plugins`
- `events`
- `fragments`
- `surfaces`
- `doctor`
- `dashboard`
- `status`
- `restart`
- `locking`
- `cleanup`

The first automated version should prioritize phases 1, 2, 3, 4, 6, 7, 9, 10, 11, and cleanup. Dashboard visual behavior can remain semi-manual because it depends on the Swift UI relay and human inspection.
