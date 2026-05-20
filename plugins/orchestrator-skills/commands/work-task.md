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

1. Move the task into implementation:
   ```bash
   craft task state set {task-id} in-progress \
     --stage implement \
     --reason "work started" \
     --log "Work Started"
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

5. Diffhub's comments API is now the source of truth for review. Both `review-pr` (Step 7) and the human import or create inline comments through diffhub; `babysit-diffhub` (Step 8) watches the read-only API for new actionable comments.

## Step 7: Kick off Cross-Model Review (background)

Self-review is biased — you tend to miss issues your own model already accepted. Spawn a **different-model reviewer** via `run-bg review-pr` so the local-review loop in Step 8 can start immediately and run in parallel with the reviewer.

```bash
"$CRAFT_ROOT/plugins/orchestrator-skills/scripts/run-bg" review-pr --worktree "$(pwd)"
# → review-pr.pid=NNNNN  (logs at .orchestrator/review-pr.log)
```

Default reviewer: `claude --model sonnet` (override via `run-bg review-pr --reviewer ... --model ...`). Findings are imported through diffhub's `/api/comments` endpoint (body tagged `automated-review:<reviewer>-<model>`) and a summary lands in `.orchestrator/handoff/review.md` when the reviewer finishes.

The reviewer reads the LOCAL branch diff (HEAD vs `origin/HEAD`'s default branch) — not a GitHub PR. This is intentional: no PR exists yet at this step, and `gh pr view` on a re-used branch name will happily return a stale CLOSED PR from a previous attempt and send the reviewer chasing the wrong diff. Pass `--base <ref>` to override the auto-detected base branch.

## Step 8: Local Review via diffhub

Enter local review. Craft updates the queue record, stamps the work log, and plugin lifecycle hooks start the diffhub watcher. Bot reviewer findings and human comments arrive as typed runtime events.

> **IMPORTANT — this is a HUMAN review gate, not an automated-review drain.**
> The local diffhub phase exists so the operator has a real opportunity to inspect the local diff before a PR is opened. Keep waiting after the automated reviewer finishes. The absence of bot comments is **not approval**. Do not self-advance just because the diff is small, the reviewer found nothing, or the work feels finished. Only the explicit signals listed in step 7 below should end this phase.

1. Move the task into local review:
   ```bash
   craft task state set {task-id} diffhub-review \
     --stage local_review \
     --reason "local diffhub review" \
     --log "Local Review Started" \
     --log-body $'Branch: {branch}\nReviewer: {reviewer}/{model} (PID $(cat .orchestrator/review-pr.pid))'
   ```
2. Leave the agent idle until Craft injects a queue summary message like:
   ```bash
   CRAFT_EVENTS task=task-123 pending=3 counts=local_review:2,ready_for_pr:1
   ```
3. Drain and handle events in batches:
   ```bash
   craft event take {task-id} --type local_review --limit 10
   craft event take {task-id} --type ready_for_pr --limit 10
   craft event take {task-id} --type review_timeout --limit 10
   ```
   For `local_review` events, read the payload, make the fix, commit with a conventional message, and `git push --force-with-lease`. Diffhub filters out stale comments before events are delivered; moved comments include their current line in the payload.
4. **Human local review is mandatory. Do not auto-advance.**

   The agent **MUST NOT** advance because the automated reviewer finished, produced zero findings, or the diff looks small/trivial. A clean bot review is one input — not a substitute for the human review window.

   Only end this phase when one of the following actually happens:
   - **the operator explicitly asks you to create/open the PR** — e.g. types something like `"ready"`, `"lgtm"`, `"push to pr"`, `"open pr"`, `"ship it"`, or any unambiguous "go ahead" in your pane. When this happens, record the signal with `craft task signal {task-id} ready_for_pr --reason "operator requested PR"` and acknowledge the request.
   - the dashboard sends a `ready_for_pr` event.
   - the configured `babysit-diffhub` idle-timeout fires and enqueues `review_timeout`.

   If none of those have happened, remain idle for the next `CRAFT_EVENTS` wake-up. Do not synthesize approval on the operator's behalf.
5. After draining a terminal `ready_for_pr` or `review_timeout` event, move back to implementation while you open the PR:
   ```bash
   craft task state set {task-id} in-progress \
     --stage implement \
     --reason "local review complete" \
     --log "Local Review Complete" \
     --log-body "Exit: <human signal or idle-timeout from the terminal event payload>"
   ```

## Step 9: Open PR and Mark Ready

Now that local review is done, open the GitHub PR. (We skipped this until now to keep github noise out of the local iteration window.)

1. Create the PR with `gh pr create --draft`:
   - Title: conventional style, e.g. `feat: add per-entity backfill flag to URL backfill pipeline`.
   - Body: summary of changes, QA results, key decisions, anything flagged for manual review.
   - If `GITHUB_REVIEWER` is set in `craft.conf`, assign them via `--reviewer {{GITHUB_REVIEWER}}`.
2. Mark the PR ready for review immediately (`gh pr ready {number}`) — local review already covered what the draft state was protecting.
3. Move the task into PR review. Plugin lifecycle hooks read `pr:`, open/reuse the stable PR surface, start PR watching, and display related build status if a plugin provides it:
   ```bash
   craft task state set {task-id} waiting \
     --stage pr_review \
     --reason "github PR opened" \
     --set pr={pr-url} \
     --log "PR Opened" \
     --log-body "PR: {pr-url}"
   ```

## Step 10: Monitor PR Until Merge

The `pr_review` lifecycle hook starts PR watching. Craft may inject events from sources such as GitHub review comments, CI/build status, approvals, terminal PR state, or other registered plugins.

**Event-driven runtime path:**

```bash
# Stay idle until Craft injects a CRAFT_EVENTS queue summary.
# Drain events when woken, act on each payload, then wait again.
craft event take {task-id} --limit 10
# Optionally add --type <event-type> when the wake-up counts show a specific
# type you want to drain first.
```

Event handling:

Craft and enabled plugins inject typed events from sources such as GitHub review
comments, CI/build status, approvals, terminal PR state, and other registered
watchers. Read each event's `type`, `summary`, and `payload`; fix what is
actionable, record approvals without merging, and use terminal PR events to
advance to Step 11 or Failure Handling.

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
> Before returning to idle for the next `CRAFT_EVENTS` wake-up, every fixed thread MUST be both replied-to AND resolved. The full procedure (commands, retry behaviour, special cases for issue-level comments) is in `.claude/skills/babysit-pr/SKILL.md` Phase 4 step 7.

> **Reminder: do not inspect event queue files directly.**
> The queue-summary wake-up is the notification channel. When there is no
> `CRAFT_EVENTS` message, silent waiting is correct waiting. Drain with
> `craft event take` only after a wake-up, and only interrupt for genuine
> operator messages.

**On any "draft → ready" transition**: also fire the `on_ready` plugin hook:

```bash
"$CRAFT_ROOT/bin/run-hook.sh" on_ready --project-dir "$PROJECT_DIR" \
    --pr-url {pr-url} --pr-number {number} --pr-title "{pr-title}" \
    2>/dev/null || true
```

**Critical:** The ONLY reasons to exit the loop are PR merged (→ Step 11) or PR closed (→ Failure Handling). Every intermediate state — CI failures, new comments, base advances — means stay in the loop and act on it.

## Step 11: Complete Task

Only reach this step when the PR has been merged.

1. Mark the task done:
   ```bash
   craft task state set {task-id} done \
     --stage complete \
     --reason "PR merged" \
     --log "Work Completed" \
     --log-body $'PR: {pr-url}\nQA: {summary of qa results}'
   ```
2. Update `state.md` with the latest activity
3. Do NOT clean up the worktree — leave it in place. The operator will clean up worktrees manually. Runtime watcher and surface cleanup is handled by the `complete` stage hook.
4. Run `/exit` to end this session. The orchestrator will detect the session has ended and clean up the pane.

## Failure Handling

If you hit an unrecoverable error at any point:
1. Mark the task blocked:
   ```bash
   craft task state set {task-id} blocked \
     --stage blocked \
     --reason "<short blocker reason>" \
     --log "Blocked" \
     --log-body "<what you tried, what failed, what the operator needs to do>"
   ```
2. Update `state.md` to reflect the blocked task
3. Runtime watcher and surface cleanup is handled by the `blocked` stage hook.
4. Run `/exit` to end this session. The orchestrator will detect the session has ended and clean up the pane.

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
