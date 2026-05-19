#!/usr/bin/env bash
set -uo pipefail

# test-plugins.sh — Tests for plugin asset sync, queue state discovery, and hook args.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Test harness ---

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
    if "$@" 2>/dev/null; then
        pass "$label"
    else
        fail "$label" "expected success, got failure"
    fi
}

assert_false() {
    local label="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" 2>/dev/null; then
        fail "$label" "expected failure, got success"
    else
        pass "$label"
    fi
}

assert_file_contains() {
    local label="$1" file="$2" needle="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -Fx -- "$needle" "$file" >/dev/null 2>&1; then
        pass "$label"
    else
        fail "$label" "missing '$needle' in $file"
    fi
}

# --- Setup ---

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export CRAFT_ROOT="$TMPDIR/craft"
PROJECT_DIR="$TMPDIR/project"
QUEUE_DIR="$PROJECT_DIR/queue"
mkdir -p "$CRAFT_ROOT/plugins/example/project/.claude/commands"
mkdir -p "$CRAFT_ROOT/plugins/example/project/.claude/skills/example-skill"
mkdir -p "$CRAFT_ROOT/plugins/example/project/.codex/skills/example-skill"
mkdir -p "$PROJECT_DIR" "$QUEUE_DIR"/{pending,approved,in-progress,waiting,done,blocked,archive}

cat > "$PROJECT_DIR/craft.conf" << 'EOF'
PLUGINS=example
EOF

cat > "$CRAFT_ROOT/plugins/example/plugin.conf" << 'EOF'
QUEUE_STATES=diffhub-review,custom-review
EOF

cat > "$CRAFT_ROOT/plugins/example/hooks.sh" << 'EOF'
check_deps() { return 0; }
EOF

cat > "$CRAFT_ROOT/plugins/example/project/.claude/commands/example.md" << 'EOF'
# Example command
EOF

cat > "$CRAFT_ROOT/plugins/example/project/.claude/skills/example-skill/SKILL.md" << 'EOF'
---
name: example-skill
---
EOF

cat > "$CRAFT_ROOT/plugins/example/project/.codex/skills/example-skill/SKILL.md" << 'EOF'
---
name: example-skill
---
EOF

source "$REPO_ROOT/bin/lib/plugins.sh"

echo "plugin_sync_project_assets"
assert_true "syncs project assets" plugin_sync_project_assets "$PROJECT_DIR"
assert_true "links claude command" test -L "$PROJECT_DIR/.claude/commands/example.md"
assert_eq "claude command target" "$CRAFT_ROOT/plugins/example/project/.claude/commands/example.md" "$(readlink "$PROJECT_DIR/.claude/commands/example.md")"
assert_true "links claude skill file" test -L "$PROJECT_DIR/.claude/skills/example-skill/SKILL.md"
assert_true "links codex skill file" test -L "$PROJECT_DIR/.codex/skills/example-skill/SKILL.md"
assert_true "idempotent resync" plugin_sync_project_assets "$PROJECT_DIR"

rm "$PROJECT_DIR/.claude/commands/example.md"
echo "local file" > "$PROJECT_DIR/.claude/commands/example.md"
assert_false "refuses real-file conflict" plugin_sync_project_assets "$PROJECT_DIR"
rm "$PROJECT_DIR/.claude/commands/example.md"

echo ""
echo "plugin_queue_states"
states="$(plugin_queue_states "$PROJECT_DIR" | paste -sd, -)"
assert_eq "core plus plugin states" "pending,approved,in-progress,waiting,done,blocked,archive,diffhub-review,custom-review" "$states"

echo ""
echo "notify hook args"
source "$REPO_ROOT/bin/lib/queue.sh"
source "$REPO_ROOT/bin/lib/notify.sh"
QUEUE_STATES=(pending approved in-progress waiting done blocked archive diffhub-review custom-review)
export PROJECT_DIR QUEUE_DIR

task_file="$QUEUE_DIR/waiting/task-123.md"
mkdir -p "$PROJECT_DIR/tasks/task-123"
cat > "$task_file" << 'EOF'
---
id: task-123
type: pr
status: waiting
pr: https://github.com/example/repo/pull/1
---

# Test task
EOF

hook_args="$TMPDIR/hook-args.txt"
stub_runner="$TMPDIR/hook-runner"
cat > "$stub_runner" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$hook_args"
EOF
chmod +x "$stub_runner"
export CRAFT_HOOK_RUNNER="$stub_runner"
export TMUX_PANE="stub-pane"

notify_waiting task-123 "$task_file"
assert_file_contains "hook name" "$hook_args" "on_waiting"
assert_file_contains "project dir flag" "$hook_args" "--project-dir"
assert_file_contains "project dir value" "$hook_args" "$PROJECT_DIR"
assert_file_contains "task id flag" "$hook_args" "--task-id"
assert_file_contains "task id value" "$hook_args" "task-123"
assert_file_contains "task file flag" "$hook_args" "--task-file"
assert_file_contains "task file value" "$hook_args" "$task_file"
assert_file_contains "task dir flag" "$hook_args" "--task-dir"
assert_file_contains "task dir value" "$hook_args" "$PROJECT_DIR/tasks/task-123"
assert_file_contains "pr url flag" "$hook_args" "--pr-url"
assert_file_contains "pr url value" "$hook_args" "https://github.com/example/repo/pull/1"

# --- Summary ---

echo ""
echo "────────────────────────────"
echo "$TESTS_RUN tests: $TESTS_PASSED passed, $TESTS_FAILED failed"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
