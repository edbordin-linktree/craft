# /work-task — Execute a task from the queue

You are the work-task skill. Your job is to pick up a task from the project queue, do the work described in it, produce a draft PR, and then monitor the PR until it is merged.

## Input

The user provides a task filename: `$ARGUMENTS`

If no argument is provided, scan `queue/approved/` and pick the first task that has no unmet `depends_on` entries (i.e., all dependencies are in `queue/done/` or `queue/archive/`).

## Step 1: Read and Understand Context

1. Read the task file from `queue/approved/$ARGUMENTS` (or `queue/in-progress/$ARGUMENTS` if resuming)
2. Parse the YAML frontmatter to understand: type, milestone, dependencies, repos, QA requirements, branch name
3. Read the project plan: `docs/plan.md`
4. Read the relevant milestone doc: `docs/milestones/{milestone}.md`
5. Read any ADRs referenced in the task or milestone
6. Read `state.md` for current project context

## Step 2: Move Task to In-Progress

1. Update the task file's `status:` field from `approved` to `in-progress`
2. Move the file: `queue/approved/{task}.md` → `queue/in-progress/{task}.md`
3. Update the cmux sidebar badge so the operator can see the queue state at a glance:
   ```bash
   "$CRAFT_ROOT/plugins/orchestrator-skills/scripts/set-task-state" {task-id} in-progress
   ```
4. Append a work log entry with timestamp:
   ```
   ### Work Started — {timestamp}
   ```

## Step 3: Set Up Worktrees

The orchestrator pre-created `tasks/{task-id}/` (the task directory) and dropped you in it as your cmux workspace cwd. Worktrees go in there as siblings — one per repo. The task directory holds task-scoped state alongside the worktrees, so a multi-repo task keeps everything for one task under one parent.

1. Read the `repos:` and `branch:` fields from the task frontmatter.
2. For each repo in `repos:`, create a worktree as a subdirectory of the task dir:
   - Worktree path: `tasks/{task-id}/{repo-name}/` (e.g. `tasks/task-001/linktree-backend/`).
   - Find the main clone of the repo. Check `repos/{repo-name}` (legacy layout) then `~/code/{repo-name}`. Use that as the git dir.
   - Run: `git -C {main-clone} worktree add tasks/{task-id}/{repo-name} -b {branch} origin/main` (or check out the branch if it already exists).
3. The task dir itself is the right cwd for state files (`tasks/{task-id}/.orchestrator/...`) and a useful anchor for switching between worktrees in a multi-repo task.
4. Do all code work inside the relevant repo's worktree, NOT in `repos/` or `~/code/`.

## Step 4: Do the Work

1. Navigate to the primary repo's worktree: `tasks/{task-id}/{primary-repo}/` (the first entry in `repos:`).
2. Read existing code to understand the codebase before making changes.
3. Implement the changes described in the task's Summary and Acceptance Criteria.
4. Write clean, well-structured code following the repo's existing conventions.
5. Append progress notes to the Work Log section as you go.
6. For a multi-repo task, navigate between worktrees as needed (`cd ../{other-repo}`). The task dir is one level up from each worktree.

## Step 5: Run QA (per the task's `qa:` spec)

Read the `qa:` block from the task frontmatter and execute each enabled check:

- **`unit_tests: true`** — Run the repo's unit test suite. If tests fail, fix the code. If you can't fix it, note the failure in the work log.
- **`integration_tests: true`** — Run integration tests. Same approach as unit tests.
- **`local_validation: "command"`** — Run the specified command and verify it succeeds. Log the output.
- **`qa_env: true`** — Do NOT attempt this. Add a note to the work log: "QA environment validation required — flagged for {{OPERATOR_NAME}}."
- **`prod_validation: true`** — Do NOT attempt this. Add a note to the work log: "Production validation required — flagged for {{OPERATOR_NAME}}."

If any automated QA step fails and you cannot fix it after 2 attempts:
1. Move the task to `queue/blocked/`
2. Update status to `blocked`
3. Append a detailed explanation to the Work Log
4. Stop — do not create a PR

## Step 6: Push Branch + Launch diffhub (no PR yet)

We push the branch so diffhub can show the local diff against the base, but we do NOT open a GitHub PR yet — local review happens first.

1. Stage and commit all changes using conventional commit style: `feat: {summary}`, `fix: {summary}`, etc. Do NOT use task IDs in commit messages.
2. Push the branch to the remote (`git push -u origin <branch>`).
3. Capture the branch and base into the work log for the cross-model reviewer to consume.
4. **Launch diffhub** via the helper script. It picks cmux mode automatically when `CMUX_WORKSPACE_ID` is set, writes `.orchestrator/diffhub.{log,pid,surface}`, and prints the URL on stdout so you don't have to grep for it.

   ```bash
   "$CRAFT_ROOT/plugins/orchestrator-skills/scripts/launch-diffhub" --repo "$(pwd)"
   # → diffhub.url=http://127.0.0.1:NNNN
   # → diffhub.pid=NNNNN
   # → diffhub.surface=surface:NN   (only under cmux)
   ```

   Append the diffhub URL to the work log so the operator can find it.

5. Diffhub's comments file (`.git/diffhub-comments.json`) is now the source of truth for review. Both `review-pr` (Step 7) and the human can write inline comments there; `babysit-diffhub` (Step 8) watches for them.

## Step 7: Kick off Cross-Model Review (background)

Self-review is biased — you tend to miss issues your own model already accepted. Spawn a **different-model reviewer** via `run-bg review-pr` so the local-review loop in Step 8 can start immediately and run in parallel with the reviewer.

```bash
"$CRAFT_ROOT/plugins/orchestrator-skills/scripts/run-bg" review-pr --worktree "$(pwd)"
# → review-pr.pid=NNNNN  (logs at .orchestrator/review-pr.log)
```

Default reviewer: `claude --model sonnet` (override via `run-bg review-pr --reviewer ... --model ...`). Findings stream into `.git/diffhub-comments.json` (inline, tagged `automated-review:<reviewer>-<model>`) and a summary lands in `.orchestrator/handoff/review.md` when the reviewer finishes.

The reviewer reads the LOCAL branch diff (HEAD vs `origin/HEAD`'s default branch) — not a GitHub PR. This is intentional: no PR exists yet at this step, and `gh pr view` on a re-used branch name will happily return a stale CLOSED PR from a previous attempt and send the reviewer chasing the wrong diff. Pass `--base <ref>` to override the auto-detected base branch.

## Step 8: Local Review via diffhub

Move the task into the new `diffhub-review` queue state and run the local babysit loop. Bot reviewer findings AND human comments stream into `.git/diffhub-comments.json` in parallel; the agent addresses each new comment as it arrives.

> **IMPORTANT — this is a HUMAN review gate, not an automated-review drain.**
> The local diffhub phase exists so the operator has a real opportunity to inspect the local diff before a PR is opened. Keep waiting after the automated reviewer finishes. The absence of bot comments is **not approval**. Do not self-advance just because the diff is small, the reviewer found nothing, or the work feels finished. Only the explicit signals listed in step 7 below should end this phase.

1. Update the task frontmatter: `status: diffhub-review`, `diffhub_review_started:` ISO 8601 timestamp.
2. Move the file: `queue/in-progress/{task}.md` → `queue/diffhub-review/{task}.md`. Also update the cmux badge:
   ```bash
   "$CRAFT_ROOT/plugins/orchestrator-skills/scripts/set-task-state" {task-id} diffhub-review
   ```
3. Append a work log entry:
   ```
   ### Local Review Started — {timestamp}
   Branch: {branch}
   Reviewer: {reviewer}/{model} (PID $(cat .orchestrator/review-pr.pid))
   ```
4. Start the local watcher as a background subprocess. **The watcher has a 2-hour idle-timeout**: if no new comments arrive for that long, it touches the sentinel itself and exits, auto-advancing to the PR phase. This is intentional — it lets overnight runs gather github-bot review feedback in the diffhub phase so the morning human sees a polished PR. Pass `--idle-timeout 0` to disable, or a different value (in seconds) to tune.
   ```bash
   "$CRAFT_ROOT/plugins/orchestrator-skills/scripts/run-bg" babysit-diffhub --worktree "$(pwd)"
   ```
5. Run the wake-up loop. **You MUST run this `Bash` tool call and block on it** — without it, the watcher writes to disk and nothing happens:
   ```bash
   "$CRAFT_ROOT/plugins/orchestrator-skills/scripts/await-diffhub-review" --repo "$(pwd)"
   # exit 0 = stdout has new comment bullets; act on each, then re-run this script
   # exit 2 = sentinel fired (human signal OR idle-timeout); advance to teardown
   ```

   > **`await-*` is the notification channel — do not poll it.**
   >
   > Once the `Bash` tool call is running and blocked, the agent **MUST NOT**
   > issue empty `write_stdin` calls, short follow-up bash commands, or
   > repeated `ls`/`cat` checks against the pending file just to "see if
   > anything happened". The script itself is the wake-up mechanism: it
   > exits with a status code AND emits stdout the instant there's work
   > to do. The platform will deliver that output and the agent will
   > resume — without you doing anything.
   >
   > **Codex-specific guidance** (codex doesn't have async notifications
   > from background terminals, so this mechanic is doing all the work):
   > - Run `await-diffhub-review` as a single blocking foreground `Bash` /
   >   shell tool call. Give it a long timeout (hours, or whatever the host
   >   permits) — the script's own `--idle-timeout` is what governs the
   >   maximum wait, not your tool timeout.
   > - Do NOT use a short polling pattern (e.g. `timeout 30 await-…`
   >   repeated in a loop). That's how token burn happens. The single
   >   blocking call IS the right pattern.
   > - If the operator interrupts you (escape / message), the watcher
   >   subprocesses (`babysit-diffhub`, `review-pr`, `diffhub`) keep
   >   running in the background — they're either launchctl-managed
   >   (macOS) or detached. When you answer the operator and re-enter the
   >   `await-diffhub-review` loop, it resumes from the watcher's current
   >   state: any comments that landed during the interrupt are still in
   >   `.git/diffhub-comments.json` / `.orchestrator/diffhub-pending.md`
   >   and the next await call returns them immediately.
   >
   > Only interrupt the await call if:
   > - the operator sends you a message (e.g. "ready", "lgtm", a question);
   > - some unrelated event genuinely requires immediate action.
   >
   > Status updates while await is blocked should be sparse — silent waiting
   > is correct waiting. Repeated polling burns tokens for zero information.
   > This applies to **both** `await-diffhub-review` (this step) and
   > `await-pr-event` (Step 10).
6. For each bullet returned (exit 0): read the file:line, read the comment body, make the fix (Edit / Write), commit with a conventional message, `git push --force-with-lease`. Then re-enter the wake-up loop (re-run `await-diffhub-review`).
7. **Human local review is mandatory. Do not auto-advance.**

   The agent **MUST NOT** touch `.orchestrator/ready-for-pr` because the automated reviewer finished, produced zero findings, or the diff looks small/trivial. A clean bot review is one input — not a substitute for the human review window.

   Only end this phase when one of the following actually happens:
   - **the operator explicitly asks you to create/open the PR** — e.g. types something like `"ready"`, `"lgtm"`, `"push to pr"`, `"open pr"`, `"ship it"`, or any unambiguous "go ahead" in your pane. When this happens, advance the task on their behalf by running `touch .orchestrator/ready-for-pr` (the wake-up loop will see the sentinel and exit on its next poll). Acknowledge the request in your reply so the operator knows you've recorded it.
   - the operator (or the dashboard's "✓ ready for PR" button) touches `.orchestrator/ready-for-pr` directly.
   - the configured `babysit-diffhub` idle-timeout fires and the watcher itself touches the sentinel.

   If none of those have happened, stay in the `await-diffhub-review` loop. Use idle time to address any new bot or human comments that arrive — but do not synthesize approval on the operator's behalf.
8. When `await-diffhub-review` exits 2, tear down the entire local-review setup so the workspace honestly reflects "no longer watching":
   ```bash
   "$CRAFT_ROOT/plugins/orchestrator-skills/scripts/cleanup-review-stage" --repo "$(pwd)"
   # → kills review-pr.pid + babysit-diffhub.pid, stops diffhub, closes its cmux surface
   ```
9. Move the file back: `queue/diffhub-review/{task}.md` → `queue/in-progress/{task}.md`, status `in-progress`. Update the cmux badge: `"$CRAFT_ROOT/plugins/orchestrator-skills/scripts/set-task-state" {task-id} in-progress`. Append a work-log entry like `### Local Review Complete — {timestamp}` (note in the entry whether exit was via human signal or idle-timeout — read `.orchestrator/diffhub-pending.md` for the last bullet, which will say `human signal:` or `idle timeout:`).

## Step 9: Open PR and Mark Ready

Now that local review is done, open the GitHub PR. (We skipped this until now to keep github noise out of the local iteration window.)

1. Create the PR with `gh pr create --draft`:
   - Title: conventional style, e.g. `feat: add per-entity backfill flag to URL backfill pipeline`.
   - Body: summary of changes, QA results, key decisions, anything flagged for manual review.
   - If `GITHUB_REVIEWER` is set in `craft.conf`, assign them via `--reviewer {{GITHUB_REVIEWER}}`.
2. Mark the PR ready for review immediately (`gh pr ready {number}`) — local review already covered what the draft state was protecting.
3. **Open the PR in cmux as a browser tab in a right-side split pane** so the operator can review/comment alongside the agent's terminal. Fire-and-forget; cmux will tear it down with the workspace when the task closes.
   ```bash
   "$CRAFT_ROOT/plugins/orchestrator-skills/scripts/open-pr-surface" "{pr-url}" \
       >/dev/null 2>&1 || true
   ```
4. Capture the PR URL: update task frontmatter `pr: {pr-url}`; append to work log.
5. Update frontmatter: `status: waiting`, `waiting:` ISO 8601 timestamp.
6. Move the file: `queue/in-progress/{task}.md` → `queue/waiting/{task}.md`. Update the cmux badge:
   ```bash
   "$CRAFT_ROOT/plugins/orchestrator-skills/scripts/set-task-state" {task-id} waiting
   ```
7. Append:
   ```
   ### PR Opened — {timestamp}
   PR: {pr-url}
   ```

## Step 10: Monitor PR Until Merge

Delegate to the **`babysit-pr` skill**. It handles the structured phase loop (conflicts → CI → comments → readiness), runs a `watch-pr` background script that polls GitHub at 30s without burning agent tokens, and only wakes you when something actually changes.

**Recommended approach (Mode B — event-driven):**

```bash
# 1. Start the watcher as a background subprocess.
"$CRAFT_ROOT/plugins/orchestrator-skills/scripts/run-bg" watch-pr --pr {number} --worktree "$(pwd)"

# 1b. Open the bk-status viewer for this PR if a Buildkite check exists.
# Idempotent + tolerant of "no BK check yet": safe to call speculatively
# right after PR creation and again after merge. Fires once and reuses any
# existing bk-status browser surface in this workspace.
"$CRAFT_ROOT/plugins/orchestrator-skills/scripts/show-build-status" {number} \
    >/dev/null 2>&1 || true

# 2. Run the wake-up loop (one Bash tool call per iteration). Read the
#    babysit-pr skill at .claude/skills/babysit-pr/SKILL.md for the full
#    protocol. Outline:
"$CRAFT_ROOT/plugins/orchestrator-skills/scripts/await-pr-event" --repo "$(pwd)"
# Exit codes:
#   0  stdout has new event bullets — act on each per babysit-pr skill:
#        - Phase 2 (Conflicts): resolve, push --force-with-lease
#        - Phase 3 (CI):        diagnose failed check, fix, commit, push
#        - Phase 4 (Comments):  triage new review/PR comments — see rule below
#        - Phase 5 (Readiness): wait for human to merge (we never merge)
#      Then re-run await-pr-event.
#   3  PR is MERGED — advance to Step 11.
#   4  PR is CLOSED — see Failure Handling.

# Clean up the watcher when the loop ends.
"$CRAFT_ROOT/plugins/orchestrator-skills/scripts/cleanup-pr-stage" --repo "$(pwd)"

# 3. Belt-and-braces: ensure bk-status is open at exit time too. The
#    pre-loop call in step 1b may have run before the Buildkite check
#    appeared on the PR; calling again is idempotent (reuses an existing
#    surface if one exists, otherwise creates one in the workspace's
#    browser pane alongside the diffhub / PR tabs).
"$CRAFT_ROOT/plugins/orchestrator-skills/scripts/show-build-status" {number} \
    >/dev/null 2>&1 || true
```

> **Phase 4 completion rule — a thread is not "handled" until `isResolved: true`.**
>
> Replying is only step 3 of 5. Without the resolve + verify, the thread reappears as a new event next iteration (you may even see your own reply come back). For every actionable thread:
>
> 1. Make the code change.
> 2. Commit and push (capture `$SHORT_SHA`).
> 3. Reply referencing the fix commit.
> 4. Resolve via GraphQL `resolveReviewThread`.
> 5. Verify the thread does NOT appear in `reviewThreads { isResolved: false }` on the next snapshot.
>
> Before re-entering `await-pr-event`, every fixed thread MUST be both replied-to AND resolved. The full procedure (commands, retry behaviour, special cases for issue-level comments) is in `.claude/skills/babysit-pr/SKILL.md` Phase 4 step 7.

> **Reminder: do not poll `await-pr-event` while it's blocking.**
> The same rule as the diffhub-review phase (see Step 8.5) applies here.
> Once the `Bash` tool call is running, the script will exit and emit
> stdout the moment there's something to do — the agent is woken by that,
> not by repeated `write_stdin` / `ls` / `cat` checks. Silent waiting is
> correct waiting. Only interrupt for genuine operator messages.

**On any "draft → ready" transition**: also fire the `on_ready` plugin hook:

```bash
"$CRAFT_ROOT/bin/run-hook.sh" on_ready --project-dir "$PROJECT_DIR" \
    --pr-url {pr-url} --pr-number {number} --pr-title "{pr-title}" \
    2>/dev/null || true
```

**Fallback (Mode A — inline polling, only if `watch-pr` or `gh`/`jq` unavailable):** Run a `while true; do gh pr view ...; sleep 120; done` loop with the same phase actions, paying agent tokens per iteration. See `.claude/skills/babysit-pr/SKILL.md` for the Mode A template.

**Critical:** The ONLY reasons to exit the loop are PR merged (→ Step 11) or PR closed (→ Failure Handling). Every intermediate state — CI failures, new comments, base advances — means stay in the loop and act on it.

## Step 11: Complete Task

Only reach this step when the PR has been merged.

1. Update the task frontmatter: set `status: done` and set `done:` to the current UTC timestamp in ISO 8601 format (e.g. `2024-01-15T14:30:00Z`)
2. Move the file: `queue/waiting/{task}.md` → `queue/done/{task}.md`. Update the cmux badge:
   ```bash
   "$CRAFT_ROOT/plugins/orchestrator-skills/scripts/set-task-state" {task-id} done
   ```
3. Append a completion entry to the Work Log:
   ```
   ### Work Completed — {timestamp}
   PR: {pr-url}
   QA: {summary of qa results}
   ```
4. Update `state.md` with the latest activity
5. Do NOT clean up the worktree — leave it in place. The operator will clean up worktrees manually.
6. **Defensive cleanup** — most of this should already be done (Step 8 tore down review stage; Step 10's cleanup-pr-stage tore down the PR watcher). Belt-and-braces:
   ```bash
   "$CRAFT_ROOT/plugins/orchestrator-skills/scripts/cleanup-review-stage" --repo "$(pwd)" || true
   "$CRAFT_ROOT/plugins/orchestrator-skills/scripts/cleanup-pr-stage"     --repo "$(pwd)" || true
   ```
7. Run `/exit` to end this session. The orchestrator will detect the session has ended and clean up the pane.

## Failure Handling

If you hit an unrecoverable error at any point:
1. Move the task to `queue/blocked/{task}.md`
2. Set `status: blocked` in frontmatter, set `blocked:` to the current UTC timestamp in ISO 8601 format, and set `one_shot: false`. Update the cmux badge:
   ```bash
   "$CRAFT_ROOT/plugins/orchestrator-skills/scripts/set-task-state" {task-id} blocked
   ```
3. Write a clear explanation in the Work Log: what you tried, what failed, what the operator needs to do
4. Update `state.md` to reflect the blocked task
5. Clean up any background subprocesses you may have started:
   ```bash
   "$CRAFT_ROOT/plugins/orchestrator-skills/scripts/cleanup-review-stage" --repo "$(pwd)" || true
   "$CRAFT_ROOT/plugins/orchestrator-skills/scripts/cleanup-pr-stage"     --repo "$(pwd)" || true
   ```
6. Run `/exit` to end this session. The orchestrator will detect the session has ended and clean up the pane.

## Important Rules

- NEVER merge a PR — only create draft PRs
- NEVER modify files outside the task's worktree
- ALWAYS work in the task's worktree (`tasks/{task-id}/{repo}/`), never in `repos/` or `~/code/`
- ALWAYS read existing code before modifying it
- ALWAYS run the QA checks specified in the task before creating the PR
- ALWAYS update the Work Log as you go — this is the operator's audit trail
- ALWAYS use the branch name from the task's `branch:` frontmatter
- ALWAYS use conventional commit messages (`feat:`, `fix:`, `refactor:`, etc.) — never prefix with task IDs
- ALWAYS scope `gh pr view`/`gh pr list` to `--state open` when checking for an existing PR — a closed PR on the same branch name may linger from a previous attempt and will mislead you. The PR you care about for this run is the one you create in Step 9.
- If the task's `depends_on` lists tasks that are NOT in `done/` or `archive/`, STOP and move the task to `blocked/` with an explanation
