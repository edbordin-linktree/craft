# Craft

Run coding tasks in parallel with autonomous AI agents. You define the work, approve what runs, and review the PRs — everything in between is automated.

## Key Principles

- **The project folder is the state machine.** Files on disk represent state. No database. Everything is human-readable and editable.
- **You review at two gates.** Task approval and PR merge. Everything in between is automated.
- **Agents never merge.** They create draft PRs, self-review, and respond to feedback. You decide when to merge.
- **Blocked is safe.** If an agent can't proceed, it stops and explains why rather than guessing.
- **Isolated worktrees.** Each task gets its own git worktree, so parallel tasks don't conflict.

## Prerequisites

You'll need these installed before using craft:

- **git**, **gh** (GitHub CLI), **jq** — for repo operations and PR management
- **tmux** or **cmux** — for managing parallel agent sessions ([tmux](https://github.com/tmux/tmux), [cmux](https://cmux.com))
- An AI agent CLI — **claude** (Claude Code) is the default, **codex** also supported

Run `craft doctor` after installing to verify everything is in place.

## Install

**macOS (Homebrew):**

```bash
brew tap stlasalle/craft
brew install craft
```

**macOS or Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/stlasalle/craft/main/install.sh | bash
```

Then verify:

```bash
craft doctor
```

## Get Started

### 1. Create a project

```bash
craft init my-project
```

### 2. Start craft

```bash
craft my-project
```

This opens a session with two windows:
- **orchestrator** — the dashboard, shows queue status and active agents
- **architect** — a Claude session pre-loaded with your project context

The architect window is your starting point. From there you can:
- Write or refine your project plan (`docs/plan.md`)
- Pull in docs or context from external sources
- Run `/generate-milestone` to plan your first milestone
- Run `/split-milestone` to break it into executable tasks
- Or just create a task directly

### 3. Approve and run

Tasks start in `queue/pending/`. Move them to `queue/approved/` when you're ready:

```bash
mv queue/pending/task-001.md queue/approved/
```

The orchestrator picks up approved tasks automatically, spins up an agent per task, and shows progress on the dashboard.

### 4. Review PRs

Each agent creates a **draft PR**, runs QA, and self-reviews. You get notified (via Slack if configured), review the PR, and merge. The agent handles CI failures and review comments while it waits.

That's it. Tasks flow through: `pending` → `approved` → `in-progress` → `waiting` → `done`.

---

## How It Works

### The Queue

The project folder *is* the state machine. Tasks are markdown files that move between directories:

```
queue/
  pending/        Tasks defined but not yet approved
  approved/       Ready to run — orchestrator picks these up
  in-progress/    An agent is actively working
  waiting/        PR created, waiting for review
  done/           PR merged
  blocked/        Agent hit an unrecoverable error
```

### What an Agent Does

For each task, the agent:

1. Reads the task file, project plan, milestone docs, and ADRs
2. Creates a git worktree for isolated work
3. Implements the changes
4. Runs QA (unit tests, integration tests, custom validation)
5. Creates a **draft** PR with conventional commits
6. Self-reviews the diff
7. Polls the PR — responds to review comments, fixes CI failures
8. Moves to `done/` when the PR merges

Agents never merge PRs. You review at two gates: **task approval** and **PR merge**.

### Task Files

Tasks are markdown with YAML frontmatter:

```yaml
---
id: task-001
milestone: m1-foundation
status: pending
workflow: standard-pr
workflow_options: {}
depends_on: []
repos: [my-repo]
branch: feat/add-feature
qa:
  unit_tests: true
  integration_tests: false
  local_validation: "npm test"
---

## Summary
Add the thing.

## Acceptance Criteria
1. The thing works.
```

Key fields:

| Field | Description |
|---|---|
| `id` | Sequential ID: `task-001`, `task-002`, etc. |
| `milestone` | Which milestone this belongs to, e.g. `m1-foundation` |
| `depends_on` | Task IDs that must complete first |
| `workflow` | Workflow preset to execute; defaults to `standard-pr` |
| `workflow_options` | Small typed options passed to workflow prompt rendering and stage hooks |
| `parent` | Optional display-only parent task ID for dashboard grouping |
| `repos` | Repos the task touches (worktrees created for each) |
| `branch` | Git branch name for the PR |
| `qa` | What validation to run before creating the PR |
| `agent` | Override the default agent for this task (optional) |
| `agent_model` | Override the workflow or provider default model for this task (optional) |

Draft tasks live in `queue/drafts/` with `status: draft`. They reserve task IDs but are not executed until promoted:

```bash
craft task promote-draft task-001
```

Task behavior comes from `workflow:`. Parent records can use a human-readable `title:` and child tasks can point at them with `parent:` for dashboard grouping. Keep execution ordering in `depends_on`.

Set `skill:` only for one-off legacy command dispatch. When `skill:` is absent, Craft renders the selected workflow preset into the launch prompt.

### Agent Providers

Craft is agent-agnostic. Set the default in project config:

```bash
craft config my-project DEFAULT_AGENT claude    # default
craft config my-project DEFAULT_AGENT codex     # use codex instead
```

Individual tasks can override with `agent:` in their frontmatter. Any CLI tool that accepts a prompt as its first argument works.

### Skills (Claude Code Slash Commands)

Each project gets these skills in `.claude/commands/`:

| Skill | What it does |
|---|---|
| `/work-task` | Main worker — executes a task end-to-end |
| `/generate-milestone` | Plans and creates a milestone interactively |
| `/split-milestone` | Breaks a milestone into executable tasks |
| `/consolidate` | Archives a completed milestone |
| `/qa-task` | Standalone QA review of a completed task |
| `/audit` | Project alignment audit against goals |

### Plugins

Plugins hook into task lifecycle events. Install and configure via the CLI:

```bash
craft plugin list                              # see what's available
craft plugin add my-project slack-dm-notify    # install + enable
craft plugin check my-project                  # verify dependencies
```

Available plugins:

| Plugin | Description |
|---|---|
| `planning` | Architect and discoverer commands plus planning skills |
| `local-review` | Pre-PR local review stage and comment event contracts |
| `bot-review` | Cross-model local branch review feeding local review comments |
| `diffhub` | Diffhub local review UI and comment ingestion |
| `babysit-pr` | GitHub PR surface, watcher, and PR review events |
| `buildkite-status` | Buildkite status surface for PR/deploy checks |
| `craft-dashboard` | Web dashboard and cmux task badges |
| `slack-dm-notify` | DMs you when a draft PR is ready for review |
| `slack-daily-thread` | Posts PR events to a daily Slack channel thread |
| `linear-sync` | Two-way sync with Linear issues |

See `craft plugin add --help` for setup instructions.

### Orchestrator Options

```bash
craft my-project --max-parallel 5 --poll-interval 30
```

| Option | Default | Description |
|---|---|---|
| `--max-parallel` | 10 | Max concurrent agents |
| `--poll-interval` | 15 | Seconds between queue checks |

### Project Config

```bash
craft config my-project                         # show all config
craft config my-project DEFAULT_AGENT codex     # set a value
```

| Key | Default | Description |
|---|---|---|
| `DEFAULT_AGENT` | `claude` | Agent CLI for task execution |
| `ARCHITECT_AGENT` | `claude` | Agent CLI for the architect window |
| `MULTIPLEXER` | `tmux` | Terminal multiplexer: `tmux` or `cmux` |
| `AGENT_TIMEOUT` | *(none)* | Max seconds per task before auto-block (per-task override: `timeout:` in frontmatter) |
| `OPERATOR_NAME` | git user | Your name, used in prompts |
| `GITHUB_REVIEWER` | gh user | GitHub username for PR reviews |
| `BRANCH_PREFIX` | *(empty)* | Prepended to branch names, e.g. `sls/` |
| `PLUGINS` | *(empty)* | Comma-separated list of enabled plugins |

### Logs

The orchestrator writes timestamped logs to `logs/orchestrator-YYYY-MM-DD.log` inside the project directory. Check these when debugging task lifecycle issues.

---

## Project Structure

```
my-project/
  docs/
    plan.md                 Master project plan
    milestones/             Milestone definitions
    adrs/                   Architectural decision records
  queue/
    pending/                Tasks awaiting approval
    approved/               Tasks ready to run
    in-progress/            Tasks being worked on
    waiting/                Tasks with PRs awaiting review
    done/                   Completed tasks
    blocked/                Tasks that need human attention
  repos/                    Git repo checkouts
  worktrees/                Agent worktrees (auto-created)
  plugins/                  Installed plugins
  logs/                     Orchestrator logs
  .claude/commands/         Skills (slash commands)
  craft.conf                Project configuration
  state.md                  Auto-maintained progress dashboard
```

---

## Development

**From source:**

```bash
git clone git@github.com:stlasalle/craft.git ~/craft
cd ~/craft
make install
```

**Switching between Homebrew and local dev:**

```bash
make install    # use local repo (changes take effect immediately)
make uninstall  # fall back to Homebrew install
```
