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

`.orchestrator/babysit-state.json` inside the worktree. Holds the previous-poll snapshot so we can diff against it and notify only on transitions. Survives agent restart.

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

## Two modes: inline loop vs background watcher

Pick one. They implement the same phase logic; they differ in where the polling happens and how often agent tokens are spent.

**You MUST run one of these two modes.** Exiting the agent after a state snapshot — relying on the orchestrator daemon to "re-spawn when there's reason to act" — is **not** a supported fallback. The orchestrator daemon only watches the queue directory, not PRs. If you skip the loop, the task silently stalls until the operator notices.

**Default: prefer Mode B (background watcher).** It only needs `gh` and `jq`. `craft-mux` is an optional convenience for cross-pane nudging (archived multi-agent flows) — in the single-agent flow it isn't used; the watcher writes transitions to `.orchestrator/watch-pr-pending.md` and the agent polls that file in its own pane via a thin bash loop.

```bash
if command -v watch-pr >/dev/null && command -v gh >/dev/null && command -v jq >/dev/null; then
    # Use Mode B (watch-pr background subprocess)
else
    # Use Mode A (inline gh-poll loop) — only as last resort
fi
```

### Topology

A single agent (the one running `/work-task`) is the executor, the babysitter, and the fixer. In Phase 2/3/4 it edits files directly with its own Edit/Write/Bash tools. No cross-agent delegation is involved.

(Earlier versions of this plugin supported a supervisor + execute-author split; that flow is archived under `plugins/orchestrator-skills/archive/` if ever needed.)

### Mode A — Inline `while` loop (default, simple)

The babysitting agent runs a `while true; do … sleep 120; done` loop inside its own pane. Every iteration the agent diffs state and runs any phases that fired. Floor of 120s on the sleep — going faster burns agent tokens for no-op polls.

```bash
while true; do
  snapshot=$(gh pr view "$PR" --json state,isDraft,mergeable,mergeStateStatus,headRefOid,reviews,comments,reviewThreads,statusCheckRollup,reviewDecision)
  state=$(jq -r .state <<<"$snapshot")
  case "$state" in
    MERGED) log "PR merged"; return 0 ;;
    CLOSED) log "PR closed without merge"; return 1 ;;
  esac

  phase_1_initialize_or_skip   # idempotent — only does work on first iteration
  phase_2_conflicts            # if mergeable == CONFLICTING
  phase_3_ci                   # if any check newly transitioned to failure
  phase_4_comments             # if new threads since last poll
  phase_5_readiness            # if green and approved

  write_state_file "$snapshot"
  sleep 120
done
```

Use this when the babysit will likely be short, when `gh`/`jq` aren't available, or when you don't want the extra moving parts. Costs agent tokens per poll (the loop body invokes the agent every 120s) — fine for short PRs, expensive for long ones.

### Mode B — `watch-pr` background script (event-driven)

A bash watcher polls GitHub on a 30s floor without invoking the agent. When it detects a transition, it appends a one-line summary to `.orchestrator/watch-pr-pending.md`. Two delivery flavours:

- **Cross-pane** (with `craft-mux` + a separate pane to nudge): the watcher also fires `craft-mux send` when the pending file flips from empty → non-empty. The target pane stays fully idle between events; the nudge appears as a new turn in that pane's Claude session and wakes it. Use only when there really is a different pane than the one calling watch-pr — i.e. multi-agent setups where the babysitting agent lives elsewhere.
- **File-only** (default, works for solo agents too): the watcher just writes to the pending file. The babysitting agent in its own pane runs a foreground bash `until` loop that blocks on the pending file. The loop is essentially free (one `[[ -s file ]]` + `sleep 5` per iteration, no agent activity until there's something to do).

Either way, agent token cost is decoupled from polling cadence — the agent only does work on real events.

Use Mode B when the babysit is expected to be long (large PR, slow CI, multi-day review window), or when responsiveness to base-branch advances matters more than simplicity.

**Invocation:**

```bash
PR_NUMBER=4242
WORKTREE="$(pwd)"

# Spawn the watcher. Two options:

# (a) File-only mode — works in BOTH solo and multi-agent. Watcher runs as a
#     background subprocess in the babysitting agent's pane. This is the
#     default; pick this unless you have a concrete reason to split panes.
watch-pr --pr "$PR_NUMBER" --worktree "$WORKTREE" \
    >.orchestrator/watch-pr.log 2>&1 &
echo $! > .orchestrator/watch-pr.pid

# (b) Cross-pane mode — multi-agent only. The babysitting agent lives in a
#     different pane and gets nudged by `craft-mux send`. Skip if you ARE the
#     pane that would receive the nudge — sending a message to your own pane
#     would create an input-during-tool-use mess.
# craft-mux spawn "task-<task-id>-watch-pr" "$WORKTREE" \
#     watch-pr --pr "$PR_NUMBER" --worktree "$WORKTREE" \
#              --supervisor-pane "<other-pane-running-the-supervisor>"
```

**Babysitting agent's responsibility while the watcher is running:**

1. **You MUST run a foreground `Bash` tool call that blocks on the pending file.** Without it, the watcher writes to disk and the agent never sees it — nothing else gives the Claude session a new turn. This is non-negotiable in file-only mode:

   ```bash
   while true; do
       # Block (cheap — bash sleeps, agent is not woken) until either:
       #   - the pending file has at least one transition line, OR
       #   - the watcher updated the state file with a terminal state.
       until [[ -s .orchestrator/watch-pr-pending.md ]] || \
             jq -er '.state | test("MERGED|CLOSED")' .orchestrator/babysit-state.json >/dev/null 2>&1; do
           sleep 5
       done

       state=$(jq -r .state .orchestrator/babysit-state.json 2>/dev/null || echo "")
       case "$state" in
           MERGED) break ;;
           CLOSED) return 1 ;;
       esac

       # Pending file has events — read, drain, hand back to the agent so it
       # can run the appropriate phase(s). The Bash tool call exits here; the
       # agent processes the pending text, then re-invokes the loop.
       cat .orchestrator/watch-pr-pending.md
       : > .orchestrator/watch-pr-pending.md
       break   # exit the bash; the agent will re-enter on next pass
   done
   ```

   In cross-pane mode the equivalent is: stay idle in your pane (don't run a loop), the watcher's `craft-mux send` will appear as a new input message and wake you. Either mechanism is mandatory.

2. When the Bash returns with a non-empty pending block, run the appropriate phase(s) for each bullet (Phase 2 conflicts / Phase 3 CI / Phase 4 comments / Phase 5 readiness).

3. Re-enter the wait loop (step 1) for the next event. Continue until the loop exits on MERGED or CLOSED.

4. When the loop exits, also clean up the watcher:
   ```bash
   [[ -f .orchestrator/watch-pr.pid ]] && kill "$(cat .orchestrator/watch-pr.pid)" 2>/dev/null
   ```

**Transitions the watcher emits** (each becomes a bullet in the pending file):
- merged / closed (terminal — watcher exits, agent proceeds to completion / blocked)
- `draft → ready` (re-engages full Phase 4 + Phase 5)
- `mergeable=CONFLICTING` (Phase 2 — *this is the "another branch merged into main" signal*)
- `mergeStateStatus=BEHIND` (base moved, no conflict yet — rebase preemptively)
- base branch SHA advanced (informational; only fires if no conflict)
- CI check transitioned to FAILURE / ACTION_REQUIRED (Phase 3)
- CI check recovered to SUCCESS (informational)
- new review threads (Phase 4)
- new issue comments
- review APPROVED / CHANGES_REQUESTED

**Lifecycle:**
- Watcher exits cleanly on PR merge (return 0) or close (return 1).
- On SIGTERM/SIGINT (e.g. the agent's pane closing), watcher exits cleanly. The agent's wake-up loop also exits when the watcher's state file shows a terminal state.

**Why this works:**
- 30s polling on the GitHub API is well under rate limits (~120 req/hr per PR; limit is 5000/hr authenticated).
- The agent's context grows only on real events, not on every poll — long babysits don't blow the context window from no-op chatter.
- The agent's wake-up loop polls a local file via bash, which is essentially free in token terms (the agent isn't invoked between sleeps).

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

   For every actionable thread you act on, all five of these MUST happen before re-entering `await-pr-event`:

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

8. **Before re-entering `await-pr-event`, run this checklist:**

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
