---
name: babysit-pr
description: Autonomous PR babysitter — polls every 2 minutes for merge conflicts, CI failures across GitHub Actions / Buildkite / Vercel / Fly.io, new review comments, and merge readiness. Auto-resolves noise, fixes what it can by resuming the execute author via craft-mux, notifies only on state transitions. Use when asked to babysit a PR, watch a PR, monitor CI, keep a PR green, handle merge conflicts, or poll PR status. Skip closed/merged PRs. On draft PRs, still react to conflicts, CI failures, and bot comments (some repos run auto-reviewer bots that fire even on drafts — those signals are real and gate the eventual review handoff). Defer human-comment triage and merge-readiness notifications until the operator marks the PR ready.
---

<!--
Adapted from babysit-pr in https://github.com/mblode/agent-skills (MIT,
© 2026 Matthew Blode). Structure, phase split, and the "notify only on state
changes" pattern are inherited from the original. Tool references swapped to
craft's while-loop + craft-mux conventions. See the upstream `references/*.md`
files for deeper detail on CI platform fallbacks, bot patterns, and the
GraphQL queries — they remain useful as reference reading.
-->

# babysit-pr

Autonomous PR monitor. Detects the PR from the current worktree, polls on a 2-minute floor, fixes what it can, and notifies on state changes. No setup questions — defaults are auto-detected.

## Scope

- Ongoing PR health: merge conflicts, CI checks, review comments, merge readiness.
- Comment triage runs autonomously inside the monitor loop — no separate approval step.
- **Draft PRs:** run Phase 2 (conflicts), Phase 3 (CI), and the bot-comment branch of Phase 4. Skip the human-comment branch of Phase 4, and skip Phase 5 (readiness) entirely, until the PR is marked ready — those decisions belong to the operator's review window. The "draft → ready" transition re-engages full behaviour on the next iteration.
- Skip: closed PRs, merged PRs.

## Inputs

When invoked from `/work-task` Step 10, the caller usually already knows:
- **PR URL or number** — captured at Step 9 (PR creation) and recorded on the task frontmatter as `pr:`.
- **Worktree path** — the current directory; `cd` here was done at Step 3 and stays for the lifetime of the task.

If invoked manually outside of work-task, auto-detect the PR from the current branch with `gh pr view --json number`.

## Context

This skill is standalone PR monitoring. It can run after any PR is opened,
whether or not the branch previously went through local diffhub review.

If a caller did run a local review phase first, some initial-review feedback may
already be addressed before this skill starts. Do not assume that happened:
triage the PR's current CI and review state from GitHub.

## State file

`.orchestrator/babysit-state.json` inside the worktree. Holds the previous-poll snapshot for the `watch-pr` stage hook so it can diff against the prior GitHub state and enqueue only transitions. Survives agent restart.

```json
{
  "pr_url": "...",
  "pr_number": 4242,
  "last_head_sha": "abc123",
  "last_mergeable": "MERGEABLE",
  "last_is_draft": false,
  "last_review_decision": "REVIEW_REQUIRED",
  "last_check_conclusions": {"ci/build": "SUCCESS", "ci/test": "FAILURE"},
  "last_thread_ids_seen": ["thread-...", "thread-..."],
  "last_polled_at": "2026-05-11T12:30:00Z",
  "detected_ci_platforms": ["github-actions", "buildkite"],
  "polls_run": 42,
  "fixes_applied": [
    {"phase": "ci", "summary": "fixed lint error", "at": "...", "sha": "def456"}
  ]
}
```

On first invocation: create with empty `last_*` fields and run an initial snapshot. On every later iteration: re-snapshot, diff, act on the diff, persist.

## Workflow checklist

Copy this to track progress:

```
- [ ] Phase 1: Initialize — auto-detect PR, snapshot state, identify CI platforms
- [ ] Phase 2: Conflicts — detect and (where safe) resolve
- [ ] Phase 3: CI — poll checks, diagnose failures, fix and push
- [ ] Phase 4: Comments — detect new threads, triage, fix
- [ ] Phase 5: Readiness — evaluate merge readiness; notify if state changed
```

## Runtime Path

Use Craft's stage lifecycle plus typed event queue. There is one supported path for normal babysitting: entering the `pr_review` stage starts/focuses the PR runtime through plugin hooks, `watch-pr` polls GitHub and enqueues typed payloads through `craft event enqueue`, and Craft injects a compact `CRAFT_EVENTS ... counts=...` wake-up only when the queue transitions from empty to non-empty.

Do not run an inline polling loop and do not inspect event queue files directly. Use `craft event take --type <type> --limit <n>` for every event read so events are drained in bounded, type-filtered batches. If `gh` or `jq` is unavailable, block the task and surface the missing dependency.

### Topology

A single agent (the one running `/work-task`) is the executor, the babysitter, and the fixer. In Phase 2/3/4 it edits files directly with its own Edit/Write/Bash tools. No cross-agent delegation is involved.

(Earlier versions of this plugin supported a supervisor + execute-author split; that flow is archived under `plugins/orchestrator-skills/archive/` if ever needed.)

### Runtime Contract

Deterministic runtime mechanics belong to Craft and plugin lifecycle hooks:

- Starting, stopping, and cleaning up `watch-pr`.
- Opening or focusing the `github-pr` and Buildkite status surfaces.
- Closing PR, diffhub, and Devin surfaces on `complete`, `blocked`, or `cleanup`.
- Delivering wake-ups when queued events first become pending.

The agent's job is only to respond to delivered events:

1. Stay idle until Craft injects a `CRAFT_EVENTS` wake-up.
2. Drain pending events by type:
   ```bash
   craft event take <task-id> --type merge_status --limit 10
   craft event take <task-id> --type ci_status --limit 10
   craft event take <task-id> --type review_comment --limit 10
   craft event take <task-id> --type pr_approval --limit 10
   craft event take <task-id> --type pr_terminal --limit 10
   ```
3. Run the matching phase(s) for each event payload.
4. When `pr_terminal` says the PR merged or closed, move the task to the matching terminal stage (`complete` or `blocked`) so lifecycle hooks perform cleanup.

**Event types the watcher emits:**
- `pr_terminal`: merged / closed.
- `merge_status`: `mergeable=CONFLICTING`, `mergeStateStatus=BEHIND`, or base branch SHA advanced.
- `ci_status`: CI failure/action-required or recovery.
- `review_comment`: new review submissions, threads, inline comments, conversation comments, or changes requested.
- `pr_approval`: human approval.
- `pr_review`: draft-to-ready and other PR-review status transitions.

**Lifecycle:**
- The `pr_review` stage hook starts `watch-pr` idempotently and opens/reuses PR visibility surfaces.
- Watcher exits cleanly on PR merge (return 0) or close (return 1).
- The `complete`, `blocked`, and `cleanup` stage hooks stop any remaining watcher process and close registered surfaces.

**Why this works:**
- 30s polling on the GitHub API is well under rate limits (~120 req/hr per PR; limit is 5000/hr authenticated).
- Event payload details stay on disk and only compact per-type counts are injected into the agent pane.
- The agent's context grows only on real events, not on every poll — long babysits don't blow the context window from no-op chatter.

## Phase 1: Initialize

Run once on the first iteration. Idempotent — subsequent iterations skip if state file exists.

1. **Detect the PR** — `gh pr view` from the worktree's current branch. If a PR number was passed by the caller (e.g. work-task Step 9), use it directly. If no PR found and none was passed, log and exit.
2. **Identify CI platforms** — scan check names in `gh pr checks` for known patterns (GitHub Actions, Buildkite, Vercel, Fly.io). Record into `detected_ci_platforms`.
3. **Initial snapshot** — write all `last_*` fields with current values so phase 5 doesn't fire spurious "broke!" notifications on the first real diff.
4. **One-time confirmation log**:

   ```
   Babysitting PR #{N}: {title}
   Polling every 2 minutes | Auto-resolve noise: yes | Auto-merge: no
   Detected CI: {platforms}
   Current: {mergeable} | {reviewDecision} | {check_summary}
   ```

## Phase 2: Conflicts

Run when `mergeable == CONFLICTING`.

1. Attempt `git fetch origin {base} && git rebase origin/{base}`.
2. Categorise each conflict file:
   - **Safe to auto-resolve** — lockfiles (`pnpm-lock.yaml`, `package-lock.json`, `Cargo.lock`, `go.sum`, `poetry.lock`), generated code (`dist/`, `build/`, files marked `DO NOT EDIT` or `Code generated …`). Take `--theirs` (base wins) and regenerate the lockfile via the project's install command if applicable.
   - **Needs author judgement** — application code. Resolve it yourself: read the conflicted file, decide the right resolution, edit with Edit/Write, `git add`, `git commit`, `git push --force-with-lease`. You wrote this code; you have the context.
3. After resolving, `git push --force-with-lease`. Never `--force` without lease — if the lease fails, someone pushed concurrently; abort and notify.
4. If unresolvable after one attempt: log and leave the conflict for the operator. Continue to the next phase.

## Phase 3: CI

Run when any check transitioned to `FAILURE` or `ACTION_REQUIRED` since the last poll (diff against `last_check_conclusions`).

1. **Per check**, fetch detail by platform:
   - **GitHub Actions** — `gh run view <run-id> --log-failed`
   - **Buildkite** — `bk build view <build-url>` (check `bk auth status` first; fall back to `gh pr checks` for summary if `bk` isn't authenticated)
   - **Vercel** — read the Vercel PR comment, or `vercel inspect <deployment> --logs`
   - **Fly.io** — `flyctl logs` against the deployment
2. **Classify** the failure:
   - **Flaky** — known-intermittent test (look at test-rerun history). Re-run once via `gh run rerun <run-id> --failed`.
   - **Code error** — failing test, lint, type. Fix it yourself with Edit/Write/Bash, commit, push.
   - **Infrastructure** — service unreachable, quota, missing secret. Notify the operator; do not retry.
   - **Dependency** — lockfile drift, missing package. Run the install command, commit the lockfile change.
3. **Cap at 2 fix attempts per check.** If still failing, log and continue polling — the operator may intervene.
4. **Flag regressions** — if a previously-passing check is now failing, surface that explicitly in the notification text ("Build regressed on commit {sha}").

## Phase 4: Comments

Run when there are new review threads or new issue comments since the last poll (diff against `last_thread_ids_seen`).

1. **Fetch** unresolved review threads (GraphQL `reviewThreads { isResolved: false }`), PR reviews, and issue-level conversation comments. Early-exit if there's nothing new and actionable.
2. **Classify each new item**:
   - **Source** — human or bot. Identify bots by author name and content patterns (vercel, linear, changeset, codecov, auto-reviewers like Sourcery / Greptile / Sourcegraph / Codacy / CodeRabbit, etc.). `github-actions[bot]` is a shared identity used by multiple tools — classify by content, not username.
   - **On draft PRs, only act on bot-sourced items.** Record human comments in the state file (`last_thread_ids_seen`) and leave them alone — the operator hasn't requested review yet, so fixing now risks churn against feedback they haven't seen. The first iteration after `isDraft` transitions from `true` to `false` should sweep the deferred human threads as new items.
   - **Severity** — critical / major / minor / nitpick. For human comments: `CHANGES_REQUESTED` → major; `APPROVED` + question → minor.
   - **Disposition** — fix or ignore-with-reason.
3. **Group inline comments** on the same file within a 3-line window — apply the highest-severity classification, fix once.
4. **Human comments are never auto-ignored.** Classify as fix unless the reviewer explicitly marked it optional or it's already addressed.
5. **Auto-resolve noise** — only for unambiguous bot output (vercel deployment success, linear sync, changeset). Post a brief reply ("auto-resolved: vercel deployment OK") before resolving the thread.
6. **Fix the real ones** — batch related comments into one logical commit per group. Apply the edits yourself; `git commit` per logical group; push after each. **Capture the commit SHA per group** — you need it in step 7.

7. **Phase 4 completion rule — a review thread is not "handled" until GitHub reports `isResolved: true`.** Replying is half the work. Without `isResolved: true`, the reviewer (human or bot) still sees an unresolved thread and will re-engage; you may also see your own reply come back as a new event next iteration and mistake it for a fresh comment.

   For every actionable thread you act on, all five of these MUST happen before waiting for the next `CRAFT_EVENTS` wake-up:

   1. **Make the code change** for the thread (or group of related threads).
   2. **Commit and push it** — capture the resulting `$SHORT_SHA` for the reply text.
   3. **Reply to the thread** referencing the fix commit. REST is most reliable for inline-comment threads:
      ```bash
      gh api -X POST repos/$OWNER/$REPO/pulls/$PR/comments/$LAST_COMMENT_DB_ID/replies \
        -f body="Fixed in $SHORT_SHA: $ONE_LINE_SUMMARY."
      ```
      `$LAST_COMMENT_DB_ID` is the `databaseId` of the **last** comment in the thread — always reply to the most recent message. See `references/github-api.md`.
   4. **Resolve the thread** via GraphQL:
      ```bash
      gh api graphql \
        -f query='mutation($threadId: ID!) { resolveReviewThread(input: { threadId: $threadId }) { thread { isResolved } } }' \
        -F threadId="$THREAD_ID"
      ```
   5. **Verify** by re-reading `reviewThreads { isResolved: false }` from the next snapshot — your thread's id MUST NOT appear in that list.

   **Special cases:**
   - **Issue-level comments and PR-level review bodies** don't have a `resolveReviewThread` equivalent. Reply (step 3) and skip steps 4-5; there's no thread object to resolve.
   - **Threads classified as ignore-with-reason**: post the reason as the reply (step 3), then still do steps 4-5. The audit trail is the same.
   - **API failure on step 4 or 5**: retry once. If it still fails, log the thread id, leave it for the operator, and continue — do not silently move on.

8. **Before returning to idle, run this checklist:**

   - [ ] Every actionable thread from this iteration has a reply.
   - [ ] Every actionable thread from this iteration is `isResolved: true` in GitHub.
   - [ ] `reviewThreads { isResolved: false }` contains no thread you intended to handle this iteration.
   - [ ] CI is at least as green as it was before this iteration's push (if not, next loop's Phase 3 will pick it up; no special handling here).

   If any box is unchecked, return to step 7 for the failing thread before looping. Do not treat "replied" as "done".

## Phase 5: Readiness

**Skip entirely while `isDraft == true`** — readiness notifications belong to the operator's review window, and a draft can't satisfy `reviewDecision == APPROVED` anyway. The "draft → ready" notification (see table below) fires from the regular state-diff once `isDraft` flips; from that point Phase 5 runs normally.

Otherwise, run on every iteration after phases 2-4 have settled.

Compute readiness:
- `mergeable == MERGEABLE`
- All required checks `SUCCESS`
- `reviewDecision == APPROVED`
- No unresolved blocking threads

**Notify only on state change** — diff each component against the prior snapshot:

| Change | Message |
|---|---|
| Any check newly green | "Build is green" |
| Any check newly red | "Build broke: {check_name}" |
| New review submitted | "New review from @{reviewer}: {state}" |
| Conflict appeared | "Merge conflict with {base_branch}" |
| Conflict cleared | "Conflict resolved" |
| Draft → ready | "PR marked as ready" |
| First time everything green | "PR #{N} ready to merge — all checks green, reviews approved" |

Do not emit "still polling" / "no change" — silence is the audit trail.

## Stopping

- PR merged → exit the loop, return success. Caller proceeds to its "complete task" step.
- PR closed without merge → exit the loop, return failure. Caller moves the task to `blocked/`.
- Operator types "stop babysitting" (interactive) → exit the loop.
- Supervisor session exits → loop dies with it (inherent to the inline-loop model; no orphan cron jobs to clean up).

On exit, write a final entry to the Work Log: polls run, fixes applied, conflicts resolved, final state.

## Anti-patterns

- Asking setup questions before starting — defaults exist for a reason.
- Polling more often than every 2 minutes — 2 minutes is the floor; rate limits punish you below that.
- Notifying every poll even when nothing changed — read the diff against state file; silence is OK.
- Force-pushing without `--force-with-lease` — risks clobbering concurrent commits.
- Auto-resolving human comments — never. Reply yes, resolve only after the fix is pushed.
- Acting on human comments while the PR is still draft — they may revise their take, or the operator may decide differently after their review. Hold human threads until `isDraft` flips to false. (Bot comments are fair game on drafts — that's the point.)
- Resolving threads without replying — reviewers can't see the reasoning.
- **Pushing a fix and considering the thread "done."** The push is one step; the reply + resolve are the other two. A thread you fixed but didn't reply on looks identical to a thread you ignored, and the reviewer (human or bot) will re-engage. The fix delegate's job ends when the commit pushes; *your* job continues through reply + resolve. If you can't resolve via the API for some reason, at minimum reply with the fix commit so the reviewer sees you acted.
- Mass-classifying `github-actions[bot]` as noise — it's a shared identity; classify by content (Danger, schema checks, etc. can be real signal).
- Fixing items that triage classified as ignore — respect the classification.
- Squashing fixes that span comment groups into one mega-commit — group by logical fix.
- Pushing before locally verifying lint/test pass (when feasible).
- Re-diagnosing while a CI check is still running — wait for the final conclusion.
- Auto-merging without explicit operator opt-in — merge is one-way; never assume.
- Using `bk` without `bk auth status` first — fall back to `gh pr checks` if auth isn't there.

## Related tools

- `plugins/orchestrator-skills/scripts/review-pr` can run a local branch review
  before PR creation in workflows that choose to use diffhub.

## Reference files

This skill ships with detailed reference docs in `references/` next to this SKILL.md. Load each one when its phase fires:

- `references/merge-conflicts.md` — Phase 2 — conflict-resolution strategies
- `references/ci-platforms.md` — Phase 3 — per-platform log-fetch commands and the Buildkite auth fallback chain
- `references/bot-patterns.md` — Phase 4 — bot detection, severity parsing, noise classification
- `references/github-api.md` — Phase 4 — GraphQL queries for fetching / replying / resolving threads
- `references/fix-plan-template.md` — Phase 4 — comment-triage plan-doc template
- `references/monitoring-setup.md` — descriptive only; the upstream uses CronCreate, we use an inline while-loop instead (see "The loop" above)

These references are copied from [mblode/agent-skills](https://github.com/mblode/agent-skills) (MIT, © 2026 Matthew Blode). License text is preserved at `references/LICENSE-MBLODE.md`.
