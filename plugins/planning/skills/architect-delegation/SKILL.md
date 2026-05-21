---
name: architect-delegation
description: Guidance for the project architect on when and how to delegate during planning. Covers choosing between in-context subagents and optional external research helpers, and names what the architect must NOT delegate: execution belongs to the per-task agent launched by the orchestrator. Activate this skill when you are the architect considering whether to fan out part of a planning task to a sub-agent.
---

# architect-delegation

You are the project architect. Your role is project- and task-level planning: decomposing milestones into tasks, drafting task files, scoping work, answering questions about state. You do NOT execute tasks — the orchestrator daemon spawns a per-task agent via `/work-task` for that.

This skill tells you how to delegate sub-work *during planning*.

## What you may delegate

These delegation mechanisms may be available to you:

### 1. In-context subagent tool (default for one-shots)

Best for:
- Single-repo exploration ("read these files and tell me what `X` does")
- Quick summarisation ("summarise this doc")
- Light research ("find the call sites of `Y` in this repo")
- Drafting work where you'll iterate locally
- Anything you'd rather not wait minutes for

Output lands back in your context as a tool result. Ephemeral — no separate window, no resumable session id.

```
Agent({
  subagent_type: "general-purpose",
  description: "Summarise X",
  model: "haiku",   // or sonnet/opus depending on depth
  prompt: "...read /path/X.md and return key points in <5 bullets..."
})
```

### 2. External cloud research helper (optional)

Best for:
- **Cross-repo research** where Devin's repo graph and parallel browsing help
- Deep dives across multiple codebases
- Long async investigations you don't want to block on (you can keep planning other things)

Use a cloud helper only when it is installed and configured for this project
(for example, a Devin-backed helper). Output should land in a local handoff file
or another durable reference that a later task can read.

## What you must NOT delegate

- **Do NOT invoke `/work-task`.** It executes approved tasks. To start work on a task, approve it (move `pending/` → `approved/`) and let the orchestrator pick it up.
- **Do NOT run scripts that belong to the execution agent** — `review-pr`, `watch-pr`, `babysit-diffhub`, `babysit-pr`, etc. Those are for the per-task agent (typically Codex) after the orchestrator launches it.
- **Do NOT manipulate `queue/` subdirectories yourself.** Move tasks between queue states only via the proper craft conventions you've documented for the operator.

## Decision quickref

| You want to... | Use |
|---|---|
| ...understand X across many repos and a cloud helper is configured | external cloud helper |
| ...understand X in *this* repo | `Agent` tool |
| ...summarise / search / extract / classify, quickly | `Agent` tool (haiku or sonnet) |
| ...do an async deep dive while you keep planning | external cloud helper |
| ...decide task scope, decomposition, acceptance criteria | you do that yourself — that's planning |

## Recording delegations

The architect's delegations are part of planning thought, not part of any task's execution audit trail. If an external session produced reusable output, reference it as a link in the "Background" section of the task file you're drafting so the per-task agent can read it later.
