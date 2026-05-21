# ADR 0001: Plugin-Driven Workflow Stages And Events

## Status

Proposed

## Context

Craft needs workflow customization without making task execution depend on one
large command prompt or on workflow presets that own all behavior. Workflow
presets should describe the happy-path stage order, while stage definitions,
event contracts, and optional behavior should be provided by core files or
plugins.

The first motivating examples are local review and Diffhub:

- A local-review plugin should provide the `local_review` stage and the
  canonical `local_review.comment` event contract.
- A Diffhub plugin should enhance `local_review`, consume lower-level review
  inputs when needed, and publish canonical local review comments for the
  agent.
- The agent should receive clean instructions, not prompts that say to handle
  an event and then disregard it because a plugin replaced it.

## Decision

Use a file-layout-driven workflow model.

Workflow presets only name happy-path stages:

```bash
STAGES="implement qa pr_review complete"
```

Stage behavior is defined by stage files. Core stages live under:

```text
stages/
  implement.md
  qa.md
  pr_review.md
  complete.md
```

Plugins provide stages by adding files under:

```text
plugins/<plugin>/stages/<stage-id>.md
```

Plugin files are opt-in. A plugin does not need empty `hooks.sh` or
`plugin.conf` files: absent hooks mean the plugin has no lifecycle hooks, and
absent config means it has no shared metadata or settings.

The filename is the stage ID. Stage files may include simple frontmatter:

```markdown
---
insert: before:pr_review
events: local_review.comment
queue_state: local-review
---

Local review feedback arrives as `local_review.comment` events.

Handle comments while this stage is active. When Craft changes the stage, stop
local review work and continue with the current workflow instructions.
```

`insert:` supports only:

- `before:<stage-id>`
- `after:<stage-id>`

There is no graph solver. If an insertion anchor is missing, workflow
resolution fails with a clear error. Duplicate providers for the same stage are
an error.

Plugins extend stages with fragments:

```text
plugins/<plugin>/fragments/stages/<stage-id>.md
```

Fragments are appended to the stage prompt in `PLUGINS` order. A stage render
has this shape:

```markdown
## Stage: local_review

<base local_review stage prompt>

### Plugin: diffhub

<diffhub local_review fragment>
```

Events use the same layout pattern. The plugin that owns a stage should define
that stage's canonical events:

```text
plugins/local-review/
  stages/local_review.md
  events/local_review.comment.md
  skills/review-comment-triage/SKILL.md
```

Other plugins can extend an event contract with fragments:

```text
plugins/diffhub/fragments/events/local_review.comment.md
```

Event definitions and fragments are included in the rendered prompt when a
stage or stage fragment references those events in frontmatter.

Plugin-owned agent skills live at `plugins/<plugin>/skills/<skill-name>/` and
are installed into both `.claude/skills/` and `.codex/skills/` for enabled
plugins. Skill-coupled helper scripts should stay inside the relevant skill
folder. Plugin runtime side effects should move into hooks before adding a
general plugin script runner.

Plugin config remains limited to non-behavioral metadata such as dependencies
and queue states:

```bash
DEPENDS_ON=local-review
```

## Stage Runtime

Stage transitions are the control plane. Events notify agents and plugins of
work or state changes; they are not approval buttons.

Use only these lifecycle hooks:

```bash
on_stage_start --stage <stage> ...
on_stage_end   --stage <stage> ...
```

There are no `on_stage_before` or `on_stage_after` hooks.

Transition flow:

1. Read the current stage.
2. If a current stage exists, run `on_stage_end --stage "$current"`.
3. Update task frontmatter: `stage`, `stage_status`, and `stage_reason`.
4. Run `on_stage_start --stage "$next"`.
5. Publish a standard event:

```json
{
  "type": "stage.changed",
  "task_id": "task-123",
  "from": "local_review",
  "to": "pr_review",
  "reason": "operator advanced"
}
```

`craft task stage advance` walks only the resolved happy path. It must not
advance into failure states.

`blocked` is an explicit terminal escape, not part of the workflow list.
Blocking should be triggered by an explicit command such as:

```bash
craft task stage set task-123 blocked --reason "..."
```

or a dedicated blocking command.

## Events

Core event publishing supports plugin interception through `on_event`.

Plugin hook API:

```bash
on_event() {
  case "$EVENT_TYPE" in
    reviewer.finding)
      diffhub_import "$EVENT_PAYLOAD"
      event_consume
      ;;
  esac
}
```

Helpers:

```bash
event_consume
event_publish <type> <payload.json> --publisher <plugin>
```

Rules:

- Default behavior is pass-through.
- If a plugin calls `event_consume`, core stops dispatch and does not enqueue
  the original event.
- Event payloads include `publisher` or `source_plugin`.
- Plugins should ignore their own emitted events when needed.
- Canonical agent-facing local review comments use `local_review.comment`.
- No event audit trail is required initially.

## Dashboard

Dashboard controls should perform stage transitions directly. For example, a
button in `local_review` should call:

```bash
craft task stage advance task-123 --reason "operator advanced"
```

There is no special `ready_for_pr` event. Stage-owned cleanup belongs in
`on_stage_end`.

## Prompt Wording Rules

Stage prompts should avoid coupling to adjacent stage names.

Prefer:

```markdown
When Craft changes the stage, stop this stage's work and continue with the
current workflow instructions.
```

Avoid:

```markdown
Advance to `pr_review`.
```

Base stages must not mention optional plugins such as Diffhub.

## Initial Plugin Split

The implementation should split runtime behavior into focused plugins:

```text
plugins/local-review/
  stages/local_review.md
  events/local_review.comment.md
  skills/review-comment-triage/SKILL.md

plugins/bot-review/
  fragments/stages/local_review.md
  skills/review-pr/SKILL.md
  scripts/review-pr

plugins/diffhub/
  plugin.conf
  fragments/stages/local_review.md
  fragments/events/local_review.comment.md
  scripts/launch-diffhub
  scripts/babysit-diffhub

plugins/pr-review/
  fragments/stages/pr_review.md
  skills/babysit-pr/SKILL.md
  scripts/watch-pr

plugins/buildkite-status/
  scripts/show-build-status

plugins/planning/
  commands/init-architect.md
  commands/init-discoverer.md
  skills/plan-reviewer/SKILL.md

plugins/craft-dashboard/
  dashboard/
  scripts/set-task-state
```

`local-review` owns the stage and canonical event contract.

`bot-review` can publish `local_review.comment` directly.

`diffhub` can consume lower-level reviewer or UI inputs, normalize/store them,
and publish `local_review.comment`.

## Consequences

- Workflow presets stay small and inspectable.
- Plugins become discoverable by file layout: provide a stage, extend a stage,
  define an event, or extend an event.
- The agent-facing prompt stays clean because plugins publish canonical events
  instead of asking the agent to disregard lower-level events.
- Plugin ordering remains simple and manageable for the initial small plugin
  set.
- More advanced event auditing, dependency solving, or workflow graphs are
  deferred.
