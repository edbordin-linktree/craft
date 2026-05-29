#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); echo "  ✓ $1"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); echo "  ✗ $1 — $2"; }

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        pass "$label"
    else
        fail "$label" "expected '$expected', got '$actual'"
    fi
}

assert_true() {
    local label="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" >/dev/null 2>&1; then
        pass "$label"
    else
        fail "$label" "expected success, got failure"
    fi
}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR/project"
QUEUE_DIR="$PROJECT_DIR/queue"
WORKTREE="$PROJECT_DIR/tasks/task-123/craft"
mkdir -p "$QUEUE_DIR"/{drafts,pending,approved,in-progress,local-review,waiting,done,blocked,archive}
mkdir -p "$WORKTREE/.orchestrator"

cat > "$PROJECT_DIR/craft.conf" <<'EOF'
MULTIPLEXER=cmux
PLUGINS=local-review,diffhub,babysit-pr
EOF

cat > "$QUEUE_DIR/in-progress/task-123.md" <<'EOF'
---
id: task-123
status: in-progress
repos: [craft]
branch: refactor/runtime
pr: https://github.com/example/repo/pull/7
---

## Summary
Runtime fixture.
EOF

chmod +x "$REPO_ROOT/test/helpers/fake-cmux"
mkdir -p "$TMPDIR/bin"
ln -s "$REPO_ROOT/test/helpers/fake-cmux" "$TMPDIR/bin/cmux"

cat > "$TMPDIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
chmod +x "$TMPDIR/bin/curl"

cat > "$TMPDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "repo" && "$2" == "view" ]]; then
  printf 'example/repo\n'
  exit 0
fi
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
  cat <<'JSON'
{
  "data": {
    "repository": {
      "pullRequest": {
        "state": "MERGED",
        "isDraft": false,
        "title": "Example PR",
        "mergeable": "MERGEABLE",
        "mergeStateStatus": "CLEAN",
        "reviewDecision": "APPROVED",
        "headRefOid": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "baseRefOid": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "baseRefName": "main",
        "reviews": {"nodes": []},
        "comments": {"nodes": []},
        "reviewThreads": {"nodes": []},
        "commits": {"nodes": [{"commit": {"statusCheckRollup": {"contexts": {"nodes": []}}}}]}
      }
    }
  }
}
JSON
  exit 0
fi
echo "fake gh: unsupported $*" >&2
exit 2
EOF
chmod +x "$TMPDIR/bin/gh"

export PATH="$TMPDIR/bin:$REPO_ROOT/bin:$PATH"
export FAKE_CMUX_STATE="$TMPDIR/cmux-state.json"
export CRAFT_ROOT="$REPO_ROOT"

source "$REPO_ROOT/bin/lib/runtime.sh"

echo "orchestrator surface scripts"
(
    cd "$WORKTREE" || exit 1
    "$REPO_ROOT/plugins/babysit-pr/scripts/open-pr-surface" \
        "https://github.com/example/repo/pull/7" --repo "$WORKTREE" >/dev/null
)
assert_eq "github-pr surface registered" "https://github.com/example/repo/pull/7" \
    "$(jq -r '.windows[0].workspaces[0].panes[].surfaces[] | select(.metadata["craft:semantic"] == "github-pr").metadata["craft:url"]' "$FAKE_CMUX_STATE")"
assert_eq "github-pr stable id" "github-pr" \
    "$(jq -r '.windows[0].workspaces[0].panes[].surfaces[] | select(.metadata["craft:semantic"] == "github-pr").metadata["craft:semantic"]' "$FAKE_CMUX_STATE")"
assert_eq "surface opened in fake cmux" "https://github.com/example/repo/pull/7" \
    "$(jq -r '.windows[0].workspaces[0].panes[].surfaces[] | select(.type == "browser").url' "$FAKE_CMUX_STATE" | head -1)"

echo ""
echo "buildkite-status stage cleanup"
tmp_state="$TMPDIR/cmux-bk.json"
jq '.windows[0].workspaces[0].panes[0].surfaces +=
    [{
      ref:"surface:77",
      type:"browser",
      title:"bk:repo#7",
      url:"http://127.0.0.1:27435/pr/example/repo/7",
      metadata: {
        "craft:semantic": "buildkite-status",
        "craft:type": "browser",
        "craft:purpose": "buildkite-status",
        "craft:title": "bk:repo#7",
        "craft:url": "http://127.0.0.1:27435/pr/example/repo/7",
        "craft:stage": "pr_review"
      }
    }]' \
    "$FAKE_CMUX_STATE" > "$tmp_state" && mv "$tmp_state" "$FAKE_CMUX_STATE"
(
    export CRAFT_ROOT="$REPO_ROOT" PROJECT_DIR="$PROJECT_DIR"
    source "$REPO_ROOT/plugins/buildkite-status/hooks.sh"
    on_stage_end \
        --stage pr_review \
        --task-id task-123 \
        --task-file "$QUEUE_DIR/in-progress/task-123.md" \
        --task-dir "$PROJECT_DIR/tasks/task-123" \
        --reason "stage advanced"
)
assert_eq "bk-status surface closed on pr_review end" "0" \
    "$(jq '[.windows[].workspaces[].panes[].surfaces[] | select(.title == "bk:repo#7")] | length' "$FAKE_CMUX_STATE")"

echo ""
echo "babysit-diffhub event queue"
printf 'http://127.0.0.1:2047\n' > "$WORKTREE/.orchestrator/diffhub.url"
(
    cd "$WORKTREE" || exit 1
    "$REPO_ROOT/plugins/diffhub/scripts/babysit-diffhub" \
        --worktree "$WORKTREE" --poll-interval 1 --idle-timeout 1 >/dev/null 2>&1
)
assert_eq "review timeout enqueued" "pending=1 counts=review_timeout:1" \
    "$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event counts task-123)"
taken="$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event take task-123 --type review_timeout --limit 1)"
assert_eq "review timeout payload retained" "review_timeout" "$(jq -r '.[0].type' <<< "$taken")"

echo ""
echo "bot-review event queue"
BOT_WORKTREE="$PROJECT_DIR/tasks/task-456/craft"
mkdir -p "$BOT_WORKTREE/.orchestrator"
cat > "$QUEUE_DIR/in-progress/task-456.md" <<'EOF'
---
id: task-456
status: in-progress
depends_on: []
repos: [craft]
branch: bot-review/events
---

## Summary
Bot review fixture.
EOF
(
    cd "$BOT_WORKTREE" || exit 1
    git init -q
    git config user.email test@example.com
    git config user.name Test
    printf 'base\n' > file.txt
    git add file.txt
    git commit -qm base
    printf 'changed\n' > file.txt
    git add file.txt
    git commit -qm changed
)
cat > "$TMPDIR/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{
  "summary": "One finding.",
  "findings": [
    {
      "file": "file.txt",
      "line": 1,
      "severity": "major",
      "category": "bug",
      "message": "The changed line is wrong."
    }
  ]
}
JSON
EOF
chmod +x "$TMPDIR/bin/claude"
(
    cd "$BOT_WORKTREE" || exit 1
    CRAFT_ROOT="$REPO_ROOT" "$REPO_ROOT/plugins/bot-review/scripts/review-pr" --worktree "$BOT_WORKTREE" --base HEAD~1 >/dev/null
)
bot_review_event="$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event take task-456 --type local_review.comment --limit 1)"
assert_eq "bot-review enqueues local review comment" "local_review.comment" "$(jq -r '.[0].type' <<< "$bot_review_event")"
assert_eq "bot-review event publisher" "bot-review" "$(jq -r '.[0].publisher' <<< "$bot_review_event")"
assert_eq "bot-review event author" "automated-review:claude-sonnet" "$(jq -r '.[0].payload.author' <<< "$bot_review_event")"
assert_eq "bot-review event body" "The changed line is wrong." "$(jq -r '.[0].payload.body' <<< "$bot_review_event")"

echo ""
echo "watch-pr event queue"
(
    cd "$WORKTREE" || exit 1
    "$REPO_ROOT/plugins/babysit-pr/scripts/watch-pr" \
        --pr 7 --worktree "$WORKTREE" --poll-interval 1 >/dev/null 2>&1
)
assert_eq "terminal PR event enqueued" "pending=2 counts=pr_approval:1,pr_review:1" \
    "$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event counts task-123)"
terminal="$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event take task-123 --type pr_review --limit 1)"
assert_eq "terminal event type" "pr_review" "$(jq -r '.[0].type' <<< "$terminal")"
assert_eq "terminal event keeps snapshot" "MERGED" "$(jq -r '.[0].payload.snapshot.state' <<< "$terminal")"

echo ""
echo "orchestrator task resume"
RESUME_PROJECT="$TMPDIR/resume-project"
RESUME_QUEUE="$RESUME_PROJECT/queue"
RESUME_TASK_DIR="$RESUME_PROJECT/tasks/task-resume"
RESUME_STATE="$TMPDIR/cmux-resume-state.json"
RESUME_HOOK_LOG="$TMPDIR/resume-hooks.log"
mkdir -p "$RESUME_QUEUE"/{drafts,pending,approved,in-progress,local-review,waiting,done,blocked,archive}
mkdir -p "$RESUME_TASK_DIR"
cat > "$RESUME_PROJECT/craft.conf" <<'EOF'
MULTIPLEXER=cmux
PLUGINS=
DEFAULT_AGENT=claude
EOF
cat > "$RESUME_QUEUE/in-progress/task-resume.md" <<'EOF'
---
id: task-resume
status: in-progress
stage: implement
stage_status: active
repos: [craft]
branch: resume/runtime
---

## Summary
Resume missing workspace fixture.
EOF
cat > "$TMPDIR/resume-hook-runner" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$RESUME_HOOK_LOG"
EOF
chmod +x "$TMPDIR/resume-hook-runner"
(
    export FAKE_CMUX_STATE="$RESUME_STATE"
    export CRAFT_HOOK_RUNNER="$TMPDIR/resume-hook-runner"
    export CRAFT_ROOT="$REPO_ROOT"
    export CRAFT_INNER_SESSION=1
    unset DASHBOARD_CMD CRAFT_DASHBOARD_PORT CRAFT_DASHBOARD_URL
    "$REPO_ROOT/bin/orchestrator.sh" "$RESUME_PROJECT" --max-parallel 1 --poll-interval 1 \
        > "$TMPDIR/resume-orchestrator.log" 2>&1 &
    orch_pid=$!
    sleep 8
    kill -TERM "$orch_pid" 2>/dev/null || true
    wait "$orch_pid" 2>/dev/null || true
)
assert_eq "resume created task workspace" "1" \
    "$(jq '[.windows[].workspaces[] | select(.metadata["craft:project-id"] == "resume-project" and .metadata["craft:task-id"] == "task-resume")] | length' "$RESUME_STATE")"
assert_eq "resume records agent surface metadata" "agent" \
    "$(jq -r '.windows[].workspaces[] | select(.metadata["craft:project-id"] == "resume-project" and .metadata["craft:task-id"] == "task-resume").panes[].surfaces[] | select(.metadata["craft:semantic"] == "agent").metadata["craft:semantic"]' "$RESUME_STATE" | head -1)"
assert_true "resume uses provider resume command" \
    bash -c "jq -e '.sent[] | select(.text | contains(\"claude --continue\"))' '$RESUME_STATE'"
assert_eq "resume hook fired from orchestrator" "1" "$(grep -c '^on_stage_resume ' "$RESUME_HOOK_LOG")"
assert_eq "resume did not fire stage start hook" "0" "$(grep -c '^on_stage_start ' "$RESUME_HOOK_LOG" || true)"
assert_true "resume appends work log" grep -q '^### Agent Session Resumed' "$RESUME_QUEUE/in-progress/task-resume.md"

echo ""
echo "normal workflow docs"
assert_true "normal work-task docs do not reference await scripts" bash -c "! grep -Eq 'await-diffhub-review|await-pr-event' '$REPO_ROOT/templates/.claude/commands/work-task.md'"
assert_true "normal work-task docs render resolved workflow" grep -q 'craft workflow render' "$REPO_ROOT/templates/.claude/commands/work-task.md"
assert_true "normal work-task docs do not hard-code local review" bash -c "! grep -Eq 'Step 8|diffhub|ready_for_pr' '$REPO_ROOT/templates/.claude/commands/work-task.md'"
assert_true "await scripts removed from normal scripts" bash -c "! test -e '$REPO_ROOT/plugins/diffhub/scripts/await-diffhub-review' && ! test -e '$REPO_ROOT/plugins/babysit-pr/scripts/await-pr-event'"

echo ""
echo "────────────────────────────"
echo "$TESTS_RUN tests: $TESTS_PASSED passed, $TESTS_FAILED failed"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
