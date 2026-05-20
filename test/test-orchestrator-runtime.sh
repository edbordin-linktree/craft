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
mkdir -p "$QUEUE_DIR"/{drafts,pending,approved,in-progress,waiting,done,blocked,archive,diffhub-review}
mkdir -p "$WORKTREE/.orchestrator"

cat > "$PROJECT_DIR/craft.conf" <<'EOF'
MULTIPLEXER=cmux
PLUGINS=orchestrator-skills
EOF

cat > "$QUEUE_DIR/in-progress/task-123.md" <<'EOF'
---
id: task-123
type: pr
status: in-progress
repos: [craft]
branch: refactor/runtime
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
runtime_write_task_session "$PROJECT_DIR" task-123 craft-project-task-123 "craft-project-task-123" craft-project-task-123 task-123

echo "orchestrator surface scripts"
(
    cd "$WORKTREE" || exit 1
    "$REPO_ROOT/plugins/orchestrator-skills/scripts/open-pr-surface" \
        "https://github.com/example/repo/pull/7" --repo "$WORKTREE" >/dev/null
)
assert_eq "github-pr surface registered" "https://github.com/example/repo/pull/7" \
    "$(jq -r '."github-pr".url' "$PROJECT_DIR/tasks/task-123/.orchestrator/surfaces.json")"
assert_eq "github-pr stable id" "github-pr" \
    "$(jq -r '."github-pr".surface_id' "$PROJECT_DIR/tasks/task-123/.orchestrator/surfaces.json")"
assert_eq "surface opened in fake cmux" "https://github.com/example/repo/pull/7" \
    "$(jq -r '.windows[0].workspaces[0].panes[].surfaces[] | select(.type == "browser").url' "$FAKE_CMUX_STATE" | head -1)"

echo ""
echo "babysit-diffhub event queue"
printf 'http://127.0.0.1:2047\n' > "$WORKTREE/.orchestrator/diffhub.url"
(
    cd "$WORKTREE" || exit 1
    "$REPO_ROOT/plugins/orchestrator-skills/scripts/babysit-diffhub" \
        --worktree "$WORKTREE" --poll-interval 1 --idle-timeout 1 >/dev/null 2>&1
)
assert_eq "review timeout enqueued" "pending=1 counts=review_timeout:1" \
    "$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event counts task-123)"
taken="$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event take task-123 --type review_timeout --limit 1)"
assert_eq "review timeout payload retained" "review_timeout" "$(jq -r '.[0].type' <<< "$taken")"

echo ""
echo "watch-pr event queue"
(
    cd "$WORKTREE" || exit 1
    "$REPO_ROOT/plugins/orchestrator-skills/scripts/watch-pr" \
        --pr 7 --worktree "$WORKTREE" --poll-interval 1 >/dev/null 2>&1
)
assert_eq "terminal PR event enqueued" "pending=2 counts=pr_approval:1,pr_terminal:1" \
    "$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event counts task-123)"
terminal="$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event take task-123 --type pr_terminal --limit 1)"
assert_eq "terminal event type" "pr_terminal" "$(jq -r '.[0].type' <<< "$terminal")"
assert_eq "terminal event keeps snapshot" "MERGED" "$(jq -r '.[0].payload.snapshot.state' <<< "$terminal")"

echo ""
echo "normal workflow docs"
assert_true "normal work-task docs do not reference await scripts" bash -c "! grep -Eq 'await-diffhub-review|await-pr-event' '$REPO_ROOT/plugins/orchestrator-skills/commands/work-task.md'"
assert_true "normal work-task docs render resolved workflow" grep -q 'craft workflow render' "$REPO_ROOT/plugins/orchestrator-skills/commands/work-task.md"
assert_true "normal work-task docs do not hard-code local review" bash -c "! grep -Eq 'Step 8|diffhub|ready_for_pr' '$REPO_ROOT/plugins/orchestrator-skills/commands/work-task.md'"
assert_true "await scripts removed from normal scripts" bash -c "! test -e '$REPO_ROOT/plugins/orchestrator-skills/scripts/await-diffhub-review' && ! test -e '$REPO_ROOT/plugins/orchestrator-skills/scripts/await-pr-event'"

echo ""
echo "────────────────────────────"
echo "$TESTS_RUN tests: $TESTS_PASSED passed, $TESTS_FAILED failed"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
