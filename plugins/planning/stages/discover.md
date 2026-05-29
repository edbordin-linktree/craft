---
workflow: discovery
queue_state: in-progress
---
Investigate one scoped problem and turn the result into one or more well-shaped Craft tasks in `queue/pending/`.

Read the task file first. Its `workflow_options` describe the discovery topic:

- `topic_slug`: kebab-case identifier for reports and task naming.
- `topic`: short title.
- `framing`: optional operator/architect context.

Your job is discovery and task design, not implementation:

1. Read project direction and constraints: `docs/plan.md`, `docs/adrs/`, recent `queue/*/task-*.md`, `state.md`, and project conventions such as `.claude/CLAUDE.md`.
2. Read the relevant code deeply enough that each generated task can cite concrete files or behavior.
3. Decide whether the topic should become one task or a small dependency-ordered set of tasks.
4. Use `.claude/skills/plan-reviewer/SKILL.md` to stress-test your task draft unless the work is trivial and fully constrained.
5. Write the resulting implementation task files to `queue/pending/task-NNN.md`.

Generated task frontmatter must use the normal execution workflow. Do not set `workflow: discovery` or `skill:` on generated implementation tasks unless the operator explicitly asks for that. The default `standard-pr` workflow is the desired executor path.

Task files should include:

- `id`, `type: pr`, `status: pending`, `depends_on`, `repos`, `branch`, and `qa`.
- Optional `linear_id` only when the operator supplied one.
- A concrete Summary, Background, Outcomes, Dependencies, Scope, Notes for the executor, and Work Log section.

Write `docs/discovery/<topic_slug>.md` only when the reasoning needs to outlive a single task, for example when queueing more than two related tasks or recording an ADR-grade decision.

When done, print each queued task path, branch, Linear ticket if any, and a one-line summary, then enter the `complete` stage.
