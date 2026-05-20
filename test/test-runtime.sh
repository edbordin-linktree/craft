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

assert_false() {
    local label="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" >/dev/null 2>&1; then
        fail "$label" "expected failure, got success"
    else
        pass "$label"
    fi
}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR/project"
QUEUE_DIR="$PROJECT_DIR/queue"
mkdir -p "$QUEUE_DIR"/{pending,approved,in-progress,waiting,done,blocked,archive,diffhub-review}
mkdir -p "$PROJECT_DIR/tasks/task-123/.orchestrator"

cat > "$PROJECT_DIR/craft.conf" <<'EOF'
MULTIPLEXER=cmux
PLUGINS=
EOF

cat > "$QUEUE_DIR/in-progress/task-123.md" <<'EOF'
---
id: task-123
type: pr
status: in-progress
depends_on: []
repos: [craft]
branch: refactor/runtime
---

## Summary
Runtime smoke fixture.
EOF

chmod +x "$REPO_ROOT/test/helpers/fake-cmux"
mkdir -p "$TMPDIR/bin"
ln -s "$REPO_ROOT/test/helpers/fake-cmux" "$TMPDIR/bin/cmux"
cat > "$TMPDIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMPDIR/bin/curl"
export PATH="$TMPDIR/bin:$REPO_ROOT/bin:$PATH"
export FAKE_CMUX_STATE="$TMPDIR/cmux-state.json"
export CRAFT_ROOT="$REPO_ROOT"

source "$REPO_ROOT/bin/lib/runtime.sh"
runtime_write_task_session "$PROJECT_DIR" task-123 craft-project-task-123 "craft-project-task-123 · Runtime smoke" craft-project-task-123 task-123

echo "task sessions"
assert_eq "writes workspace id" "craft-project-task-123" "$(jq -r '.workspace_id' "$PROJECT_DIR/tasks/task-123/.orchestrator/task-session.json")"
assert_eq "writes pane name" "task-123" "$(jq -r '.pane_name' "$PROJECT_DIR/tasks/task-123/.orchestrator/task-session.json")"

echo ""
echo "stage commands"
hook_log="$TMPDIR/hooks.log"
hook_runner="$TMPDIR/hook-runner"
cat > "$hook_runner" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$hook_log"
EOF
chmod +x "$hook_runner"
export CRAFT_HOOK_RUNNER="$hook_runner"

(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft" task stage set task-123 implement --reason "start implementation"
)
assert_eq "stage set" "implement" "$(task_field "$QUEUE_DIR/in-progress/task-123.md" stage)"
assert_eq "stage status set" "active" "$(task_field "$QUEUE_DIR/in-progress/task-123.md" stage_status)"
assert_eq "before hook fired" "1" "$(grep -c '^on_stage_before ' "$hook_log")"
assert_eq "after hook fired" "1" "$(grep -c '^on_stage_after ' "$hook_log")"

(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft" task stage advance task-123 --reason "next"
)
assert_eq "stage advance" "qa" "$(task_field "$QUEUE_DIR/in-progress/task-123.md" stage)"

(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft" task state set task-123 diffhub-review \
        --stage local_review \
        --reason "local review" \
        --set pr=https://github.com/example/repo/pull/1 \
        --log "Local Review Started" \
        --log-body "Branch: refactor/runtime"
)
assert_true "task state moved file" test -f "$QUEUE_DIR/diffhub-review/task-123.md"
assert_eq "task state updates status" "diffhub-review" "$(task_field "$QUEUE_DIR/diffhub-review/task-123.md" status)"
assert_eq "task state updates stage" "local_review" "$(task_field "$QUEUE_DIR/diffhub-review/task-123.md" stage)"
assert_eq "task state sets field" "https://github.com/example/repo/pull/1" "$(task_field "$QUEUE_DIR/diffhub-review/task-123.md" pr)"
assert_true "task state work log" grep -q '^### Local Review Started — ' "$QUEUE_DIR/diffhub-review/task-123.md"
assert_eq "task state hook fired" "1" "$(grep -c '^on_task_state_after ' "$hook_log")"

(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft" task state set task-123 in-progress --stage implement --reason "resume implementation"
)
assert_true "task state returns file" test -f "$QUEUE_DIR/in-progress/task-123.md"

echo ""
echo "event queue"
assert_true "craft-mux session override resolves task pane" bash -c "cd '$PROJECT_DIR' && '$REPO_ROOT/bin/craft-mux' --session craft-project-task-123 exists task-123"
payload1="$TMPDIR/payload1.json"
payload2="$TMPDIR/payload2.json"
printf '{"body":"one"}\n' > "$payload1"
printf '{"body":"two"}\n' > "$payload2"
(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft" event enqueue task-123 --type pr_review --summary "review one" --json "$payload1" >/dev/null
    "$REPO_ROOT/bin/craft" event enqueue task-123 --type ci_status --summary "ci two" --json "$payload2" >/dev/null
)
assert_eq "duplicate wake suppressed" "1" "$(jq '.sent | length' "$FAKE_CMUX_STATE")"
assert_eq "wake is queue summary" "CRAFT_EVENTS task=task-123 pending=1 counts=pr_review:1" "$(jq -r '.sent[0].text' "$FAKE_CMUX_STATE")"
counts="$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event counts task-123)"
assert_eq "event counts" "pending=2 counts=ci_status:1,pr_review:1" "$counts"
taken="$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event take task-123 --type pr_review --limit 1)"
assert_eq "take returns one" "1" "$(jq 'length' <<< "$taken")"
counts_after="$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event counts task-123)"
assert_eq "take deletes" "pending=1 counts=ci_status:1" "$counts_after"
(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft" task signal task-123 ready_for_pr --reason "operator requested PR" >/dev/null
)
signalled="$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event take task-123 --type ready_for_pr --limit 1)"
assert_eq "task signal enqueues event" "ready_for_pr" "$(jq -r '.[0].type' <<< "$signalled")"
assert_eq "task signal reason" "operator requested PR" "$(jq -r '.[0].payload.reason' <<< "$signalled")"

echo ""
echo "surface registry and fake cmux"
(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft-mux" open task-123 pr --url https://github.com/example/repo/pull/1 --label "PR" --owner test --stage pr_review >/dev/null
)
assert_eq "surface registered" "https://github.com/example/repo/pull/1" "$(jq -r '.pr.url' "$PROJECT_DIR/tasks/task-123/.orchestrator/surfaces.json")"
assert_eq "browser opened in right pane" "pane:2" "$(jq -r '.windows[0].workspaces[0].panes[] | select(.surfaces[]?.url == "https://github.com/example/repo/pull/1").ref' "$FAKE_CMUX_STATE")"

registry="$PROJECT_DIR/tasks/task-123/.orchestrator/surfaces.json"
tmp_json="$TMPDIR/surfaces.json"
jq '.pr.cached_surface_ref = "surface:999"' "$registry" > "$tmp_json" && mv "$tmp_json" "$registry"
(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft-mux" focus task-123 pr >/dev/null
)
assert_eq "focus adopts same-workspace browser" "surface:3" "$(jq -r '.pr.cached_surface_ref' "$registry")"

jq '.terminal = {surface_id:"terminal", kind:"terminal", label:"Terminal", owner:"test", stage:"qa", expected_workspace_id:"craft-project-task-123", cached_surface_ref:"surface:999", status:"open"}' "$registry" > "$tmp_json" && mv "$tmp_json" "$registry"
assert_false "stale non-browser is not adopted" bash -c "cd '$PROJECT_DIR' && '$REPO_ROOT/bin/craft-mux' focus task-123 terminal"

echo ""
echo "dashboard command"
export CRAFT_DASHBOARD_PORT=29999
export DASHBOARD_CMD='printf "%s %s\n" "$PROJECT_DIR" "$CRAFT_DASHBOARD_PORT" > "$PROJECT_DIR/dashboard-invoked"'
source "$REPO_ROOT/bin/lib/mux-cmux.sh"
_cmux_ensure_dashboard_server "$PROJECT_DIR" >/dev/null
assert_eq "dashboard command invoked" "$PROJECT_DIR 29999" "$(cat "$PROJECT_DIR/dashboard-invoked")"

echo ""
echo "────────────────────────────"
echo "$TESTS_RUN tests: $TESTS_PASSED passed, $TESTS_FAILED failed"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
