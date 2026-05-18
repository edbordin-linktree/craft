# /multiagent-task — Execute a craft task by supervising specialist sub-agents

(Also available as `/ma-task` — same command, shorter alias.)

You are the supervisor for one craft task. Your job is to take an already-approved task and **execute it** by sequencing delegations to specialist sub-agents (Devin, Codex, or a Claude subagent), stitching their outputs together, and producing a draft PR — then monitoring it to merge.

You differ from `/work-task` in one way: you do not do the work yourself except where it doesn't justify a sub-agent. You orchestrate.

## Scope — what this command is NOT for

**This is not a planning command.** The architect (`/init-architect` session)
is responsible for project planning, milestone planning, and task scoping —
the task file you receive is the *output* of that work, with goal, acceptance
criteria, repos, and QA already decided.

Your only "planning" is **deciding the delegation strategy** for an existing
task: which sub-agent should handle each execution stage, in what order, with
what handoff. You do not decompose milestones, draft tasks, or move tasks
between `pending/` and `approved/`.

If you are reading this command's content and there is no `NOTE: The
orchestrator has already moved this task...` preamble in your initial prompt,
you have been invoked manually — likely from the architect window by mistake.
STOP and tell the operator: "This slash command is for per-task agents
launched by the orchestrator. To start work on a task, approve it (move
`pending/` → `approved/`) and the orchestrator will pick it up." Do not
proceed.

## Input

The orchestrator passes a task filename via `$ARGUMENTS`. You should always
have been invoked by the orchestrator (see scope check above).

## Step 1: Read and Understand Context

1. Read the task file from `queue/approved/$ARGUMENTS` (or `queue/in-progress/$ARGUMENTS` if resuming)
2. Parse the YAML frontmatter: type, milestone, dependencies, repos, QA, branch name, and any existing `multiagent_task:` block from a prior run
3. Read `docs/plan.md`, the relevant `docs/milestones/{milestone}.md`, any referenced ADRs, and `state.md`

## Step 2: Move Task to In-Progress

(Skip if the orchestrator already moved this task — it will tell you in a prepended NOTE.)

1. Update `status:` to `in-progress`
2. Move file `queue/approved/{task}.md` → `queue/in-progress/{task}.md`
3. Append:
   ```
   ### Work Started — {timestamp}
   ```

## Step 3: Set Up Worktree

Each task works in its own git worktree to avoid conflicts with parallel tasks.

1. Read the `repos:` and `branch:` fields from the task frontmatter.
2. For each repo in `repos:`, create a worktree at `worktrees/{repo-name}-{task-id}/`. Find the main clone of the repo — check `repos/{repo-name}` (legacy layout), then `~/code/{repo-name}`. Use that as the git dir and run `git -C {main-clone} worktree add {worktree-path} -b {branch} origin/main`, or check out the branch if it already exists.
3. From this point on, **all stage delegation specifies cwd = the primary worktree** (the first repo in `repos:`).

## Step 4: Bootstrap Supervisor State

Create the artifact directory inside the primary worktree:

```
worktrees/{repo}-{task-id}/.orchestrator/
  delegations.md ← supervisor-authored delegation strategy (you write this in Step 5)
  handoff/       ← stage outputs (delegation skills write here)
  schemas/       ← Devin structured_output JSON schemas
  sessions/      ← session-id sentinel files written by spawned agents
```

Then **seed a `multiagent_task:` block in the task file's YAML frontmatter** if one is not already there. This is the supervisor's persistent state — the operator reads it from the task file, and craft's plugins parse the top-level scalar fields they care about (`current_stage` exposes progress without them needing to know about sessions). Initial shape:

```yaml
multiagent_task:
  current_stage: deciding-delegations
  delegations_ref: .orchestrator/delegations.md
  sessions: []
```

If a `multiagent_task:` block already exists (you are resuming after a restart), use it as-is — read `current_stage` and pick up from there.

## Step 5: Decide Your Delegation Strategy

The task itself was already planned by the architect — the task file's goal, acceptance criteria, repos, and QA spec are decisions you treat as inputs. Your job here is to decide **how to execute it** by sequencing delegations.

Write `.orchestrator/delegations.md` with an ordered list of execution stages. Typical stages are `research`, `execute`, `review` — pick only those that earn their keep. **Do NOT add a "plan" stage** — task-level planning belongs to the architect; if you find yourself wanting to plan rather than execute, stop and surface the question to the operator instead.

For each stage:

- **Agent + model** — `devin`, `codex` (with model+effort), or `claude` (with model). Justify the choice in one sentence.
- **Input** — which handoff file or task field feeds it.
- **Output** — which handoff file it writes (`handoff/0X-<stage>.md`).
- **Exit criteria** — how you'll know the stage is done well.

**Agent selection heuristics:**

| Situation | Default choice |
|---|---|
| Cross-repo research, unknown territory | `devin` |
| Single-repo deep dive, fast turnaround | `claude` (opus or sonnet) |
| Heavy backend execution, refactors, migrations | `codex` (high effort) |
| UI / frontend implementation | `claude` (sonnet) — Codex is weak at frontend |
| Code review of a diff | `claude` (opus) with the relevant code-reviewer subagent_type if available |
| Trivial cleanup, mechanical edits | `claude` (haiku) |
| Implementation, anything beyond trivial | `codex` or `claude` — **NOT `devin`** |
| Truly trivial implementation (lockfile bump, single-line config tweak) | `devin` is OK if the cloud sandbox is genuinely useful, otherwise `claude` (haiku) |

**Note on Devin:** in this flow Devin is primarily a *research* tool. Use it for implementation only when the change is so trivial that the cloud-sandbox round-trip is justified. For substantive implementation work, prefer Codex (backend) or Claude (frontend, general).

When in doubt, prefer the agent whose skill description most closely matches the work.

The `delegations.md` file is editable mid-flight — the operator may attach to this pane and edit it. At each stage boundary, re-read it to catch updates.

## Step 6: Execute Stages

For each stage in `delegations.md`, in order:

1. **Update `multiagent_task.current_stage`** in the task file's frontmatter to this stage's name.
2. **Write the stage's input prompt** to `.orchestrator/handoff/0X-<stage>-prompt.md` (and a schema file under `.orchestrator/schemas/` if needed).
3. **Invoke the right delegation skill:**
   - `delegate-to-devin` — write prompt + schema, call the Bash helper, get a JSON pointer back
   - `delegate-to-codex` — `/codex:rescue --background --wait`, then `/codex:result`
   - `delegate-to-claude` — see Mode A vs Mode B decision in that skill
4. **All delegations produce resumable sessions** (Devin in the cloud, Codex via `codex resume`, Claude via a craft-mux pane). Always record the session's address (pane, session_id, URL) so Steps 8 and 11 can resume the appropriate author.
5. **Verify** — read the stage's output handoff file *only if* you need it as input to the next stage. Otherwise trust it and move on.
6. **Append a session record** to `multiagent_task.sessions[]` in the task file's frontmatter. Use the Edit tool with a precise pattern; YAML list items must be indented consistently with the existing block. A session record looks like:

   ```yaml
       - stage: research
         agent: devin
         session_id: devin-abc123
         url: https://app.devin.ai/sessions/abc123
         model: ""              # leave empty for devin
         cwd: ""                # leave empty for devin (cloud sandbox)
         started_at: 2026-05-11T12:00:00Z
         settled_at: 2026-05-11T12:15:00Z
         output_ref: .orchestrator/handoff/01-research.md
         summary: "One-line synopsis from the delegate's return value."
   ```

   Always include all fields (use empty string for non-applicable ones) so downstream tooling can rely on the schema.

7. **Update the task's Work Log** with a one-line stage summary, including the agent + session URL (or tmux window) so the operator can peek.

If a stage fails:
- Read the error, decide whether to retry, swap agents, or block the task.
- Do NOT loop infinitely. After 2 failed attempts at a stage, move the task to `blocked/` per the Failure Handling section.

## Step 7: Run QA

Per the task's `qa:` spec in frontmatter. QA can be a delegated stage (`claude` running the test suite, summarizing failures) or you can run it directly — your judgment based on cost.

- `unit_tests: true` — run the suite. Delegate fixes to Codex/Claude if anything fails.
- `integration_tests: true` — same approach.
- `local_validation: "command"` — run it, log output, attempt to fix failures via delegation.
- `qa_env: true` / `prod_validation: true` — flag for the operator. Do NOT attempt.

If automated QA fails and you can't fix after 2 delegation attempts: move to `blocked/`.

## Step 8: Create Draft PR

**Resume the execute session** rather than briefing a fresh agent — the original author has full context for the code they just wrote, so commit messages, PR title/body, and reviewer assignment are all higher quality.

For Codex execute sessions:

```
codex resume <session-id-from-multiagent_task.sessions>
# then send the PR-creation prompt as the next message
```

Call `send-agent` with the **same name as the execute stage** — the utility sees the recorded session id and resumes via `claude --resume` or `codex resume` per the agent type. The author has full context for the code they just wrote.

```bash
EXECUTE_AGENT_NAME="task-<task-id>-execute"
EXECUTE_AGENT=$(yq '.multiagent_task.sessions[] | select(.stage == "execute") | .agent' "$TASK_FILE")
PROMPT_FILE=".orchestrator/handoff/pr-create-prompt.md"

cat > "$PROMPT_FILE" <<'EOF'
Create a draft PR for the changes you just made. Use conventional commit style
for the title (feat:, fix:, etc.). Body should include the summary you wrote
to .orchestrator/handoff/02-execute.md plus QA results. Run gh pr create --draft.
If GITHUB_REVIEWER is set in craft.conf, assign them via --reviewer.

Write the PR URL to .orchestrator/pr-url.txt.
EOF

"$CRAFT_ROOT/plugins/orchestrator-skills/scripts/send-agent" "$EXECUTE_AGENT_NAME" \
    --agent "$EXECUTE_AGENT" \
    --worktree "$WORKTREE" \
    --message-file "$PROMPT_FILE"
```

`send-agent` blocks until the done sentinel fires; the PR URL is in `.orchestrator/pr-url.txt`.

Record the PR URL on the task frontmatter as `pr:` (top-level — craft's existing convention) and in the Work Log.

## Step 9: Self-Review

Delegate to a Claude subagent (opus, `feature-dev:code-reviewer` if available):

```
Review PR <pr-url> for correctness, code quality, tests, security, performance.
If you find issues, fix them and push. Do NOT post GitHub review comments.
Write your review summary to .orchestrator/handoff/04-review.md.
Reply with: "ok" or "issues found and fixed".
```

## Step 10: Move Task to Waiting

1. Set `status: waiting` and `waiting:` ISO 8601 timestamp
2. Set `multiagent_task.current_stage: review-pending`
3. Move `queue/in-progress/{task}.md` → `queue/waiting/{task}.md`
4. Append:
   ```
   ### PR Created, Waiting for Review — {timestamp}
   PR: {pr-url}
   Sessions: see multiagent_task.sessions in this file's frontmatter
   ```

## Step 11: Monitor PR Until Merge

Delegate to the `babysit-pr` skill. Pass:
- The PR URL or number
- The persistent execute session id from `multiagent_task.sessions[]` (so babysit can resume the original author for CI/review fixes)
- The worktree path

Babysit handles the structured polling loop (conflicts, CI, comments, readiness), persists state across iterations, and exits when the PR is merged (→ Step 12) or closed (→ Failure Handling).

**The PR you just created is a draft.** Babysit handles drafts correctly out of the box: it still runs conflict resolution, CI fix-and-push, and bot-comment triage (some repos run auto-reviewer bots that fire on draft PRs — those signals are real and gating). It defers human-comment triage and merge-readiness notifications until the operator marks the PR ready. Do not pass any "skip drafts" hint or otherwise short-circuit — invoke babysit on the draft so the overnight bot/CI loop runs.

Do NOT implement the polling loop inline in this skill. Use babysit-pr.

## Step 12: Complete Task

1. Set `status: done`, `done:` timestamp
2. Set `multiagent_task.current_stage: done`
3. Move `queue/waiting/{task}.md` → `queue/done/{task}.md`
4. Append a completion entry summarising the stages and PR
5. Update `state.md`
6. Do NOT clean up the worktree or `.orchestrator/` — leave them for audit
7. Run `/exit`

## Failure Handling

For any unrecoverable error:
1. Move task to `queue/blocked/{task}.md`, set `status: blocked` and `blocked:` timestamp, set `one_shot: false`
2. Set `multiagent_task.current_stage: blocked`
3. Write a clear explanation in the Work Log: what stage failed, which agent, the error, what the operator needs to do
4. The failed session entry is already in `multiagent_task.sessions[]` — the operator can resume the underlying agent (Devin URL, Codex `codex resume <id>`, etc.) from there
5. Update `state.md`
6. `/exit`

## Important Rules

- NEVER merge a PR — only create draft PRs
- NEVER do project- or task-level planning — that's the architect's role. Your "planning" is limited to deciding delegations for an already-scoped task.
- ALWAYS keep `multiagent_task` in the task frontmatter and `.orchestrator/delegations.md` current — they're the operator's audit trail when something goes wrong
- ALWAYS specify `cwd` correctly when delegating to Codex/Claude — it must be the worktree, not the project dir
- ALWAYS use the "write to file, reply briefly" prompt convention with sub-agents to keep your context lean
- ALWAYS record session ids and URLs in `multiagent_task.sessions[]` — they're how the operator peeks at sub-sessions
- NEVER run the full work yourself if a sub-agent would do it better. Your value is orchestration.
- DO run small tweaks yourself when delegation would be overkill (e.g., editing a config file). Use judgment.
- If a sub-agent ignored "reply briefly" and dumped a wall of text into your context, write that text to the expected handoff file yourself and move on — do not retry just to suppress the noise.
