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

assert_existing_file_not_contains_regex() {
    local label="$1" file="$2" pattern="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ ! -f "$file" ]]; then
        fail "$label" "missing file: $file"
    elif grep -Eq -- "$pattern" "$file" 2>/dev/null; then
        fail "$label" "unexpected match for '$pattern' in $file"
    else
        pass "$label"
    fi
}

# --- Setup ---

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export CRAFT_ROOT="$TMPDIR/craft"
PROJECT_DIR="$TMPDIR/project"
QUEUE_DIR="$PROJECT_DIR/queue"
mkdir -p "$CRAFT_ROOT"
ln -s "$REPO_ROOT/bin" "$CRAFT_ROOT/bin"
mkdir -p "$CRAFT_ROOT/plugins/example/project/.claude/commands"
mkdir -p "$CRAFT_ROOT/plugins/example/skills/example-skill"
mkdir -p "$CRAFT_ROOT/plugins/duplicate/skills/example-skill"
mkdir -p "$CRAFT_ROOT/plugins/no-hooks"
mkdir -p "$PROJECT_DIR" "$QUEUE_DIR"/{drafts,pending,approved,in-progress,waiting,done,blocked,archive}

cat > "$PROJECT_DIR/craft.conf" << 'EOF'
PLUGINS=example
EOF

cat > "$CRAFT_ROOT/plugins/example/plugin.conf" << 'EOF'
QUEUE_STATES=extra-review,custom-review
EOF

cat > "$CRAFT_ROOT/plugins/example/hooks.sh" << 'EOF'
check_deps() { return 0; }
EOF

cat > "$CRAFT_ROOT/plugins/example/project/.claude/commands/example.md" << 'EOF'
# Example command
EOF

cat > "$CRAFT_ROOT/plugins/example/skills/example-skill/SKILL.md" << 'EOF'
---
name: example-skill
---
EOF

cat > "$CRAFT_ROOT/plugins/duplicate/skills/example-skill/SKILL.md" << 'EOF'
---
name: example-skill
---
EOF

source "$REPO_ROOT/bin/lib/plugins.sh"

echo "plugin_sync_project_assets"
assert_true "syncs project assets" plugin_sync_project_assets "$PROJECT_DIR"
assert_true "links claude command" test -L "$PROJECT_DIR/.claude/commands/example.md"
assert_eq "claude command target" "$CRAFT_ROOT/plugins/example/project/.claude/commands/example.md" "$(readlink "$PROJECT_DIR/.claude/commands/example.md")"
assert_true "links claude skill dir" test -L "$PROJECT_DIR/.claude/skills/example-skill"
assert_eq "claude skill target" "$CRAFT_ROOT/plugins/example/skills/example-skill" "$(readlink "$PROJECT_DIR/.claude/skills/example-skill")"
assert_true "links codex skill dir" test -L "$PROJECT_DIR/.codex/skills/example-skill"
assert_eq "codex skill target" "$CRAFT_ROOT/plugins/example/skills/example-skill" "$(readlink "$PROJECT_DIR/.codex/skills/example-skill")"
assert_true "idempotent resync" plugin_sync_project_assets "$PROJECT_DIR"

cat > "$PROJECT_DIR/craft.conf" << 'EOF'
PLUGINS=example,no-hooks
EOF
assert_true "plugin without hooks or config is valid for asset sync" plugin_sync_project_assets "$PROJECT_DIR"
no_hooks_missing="$(plugin_missing_dependencies "$PROJECT_DIR" no-hooks | paste -sd, -)"
assert_eq "plugin without hooks or config has no missing dependencies" "" "$no_hooks_missing"
cat > "$PROJECT_DIR/craft.conf" << 'EOF'
PLUGINS=example
EOF

rm "$PROJECT_DIR/.claude/commands/example.md"
echo "local file" > "$PROJECT_DIR/.claude/commands/example.md"
assert_false "refuses real-file conflict" plugin_sync_project_assets "$PROJECT_DIR"
rm "$PROJECT_DIR/.claude/commands/example.md"

cat > "$PROJECT_DIR/craft.conf" << 'EOF'
PLUGINS=example,duplicate
EOF
assert_false "rejects duplicate plugin skills" plugin_sync_project_assets "$PROJECT_DIR"
cat > "$PROJECT_DIR/craft.conf" << 'EOF'
PLUGINS=example
EOF
mkdir -p "$CRAFT_ROOT/plugins/needs-example"
cat > "$CRAFT_ROOT/plugins/needs-example/plugin.conf" << 'EOF'
DEPENDS_ON=example
EOF

echo ""
echo "split plugin assets"
real_project="$TMPDIR/split-plugin-project"
mkdir -p "$real_project"
cat > "$real_project/craft.conf" << 'EOF'
PLUGINS=planning,local-review,bot-review,diffhub,babysit-pr,craft-dashboard
EOF

old_craft_root="$CRAFT_ROOT"
CRAFT_ROOT="$REPO_ROOT"
assert_true "split plugins sync through generic assets" plugin_sync_project_assets "$real_project"
assert_false "planning does not override architect command" test -e "$real_project/.claude/commands/init-architect.md"
assert_true "planning discoverer command linked" test -L "$real_project/.claude/commands/init-discoverer.md"
assert_true "bot-review claude skill linked" test -L "$real_project/.claude/skills/review-pr"
assert_eq "bot-review claude skill target" "$REPO_ROOT/plugins/bot-review/skills/review-pr" "$(readlink "$real_project/.claude/skills/review-pr")"
assert_true "babysit-pr codex skill linked" test -L "$real_project/.codex/skills/babysit-pr"
assert_eq "babysit-pr codex skill target" "$REPO_ROOT/plugins/babysit-pr/skills/babysit-pr" "$(readlink "$real_project/.codex/skills/babysit-pr")"
retired_monolith="orchestrator""-skills"
assert_false "retired monolith plugin removed" test -d "$REPO_ROOT/plugins/$retired_monolith"
orchestrator_states="$(plugin_queue_states "$real_project" | sort | paste -sd, -)"
expected_orchestrator_states="$(printf '%s\n' drafts pending approved in-progress waiting done blocked archive local-review diffhub-review | sort | paste -sd, -)"
assert_eq "plugins declare their queue states" "$expected_orchestrator_states" "$orchestrator_states"
mkdir -p "$real_project/queue"/{approved,pending,in-progress,waiting,done,blocked,archive}
cat >> "$real_project/craft.conf" <<'EOF'
DISCOVERY_AGENT=claude
DISCOVERY_AGENT_MODEL=opus
EOF
assert_true "planning discoverer queues workflow task" bash -c "CRAFT_ROOT='$REPO_ROOT' PROJECT_DIR='$real_project' '$REPO_ROOT/plugins/planning/scripts/start-discoverer' smoke-topic 'Smoke topic' 'Extra framing' > '$TMPDIR/discoverer.out'"
assert_true "discoverer writes approved task" test -f "$real_project/queue/approved/task-001.md"
assert_file_contains "discoverer task workflow" "$real_project/queue/approved/task-001.md" "workflow: discovery"
assert_file_contains "discoverer task agent model" "$real_project/queue/approved/task-001.md" 'agent_model: "opus"'
CRAFT_ROOT="$old_craft_root"

echo ""
echo "plugin dependencies"
cat > "$PROJECT_DIR/craft.conf" << 'EOF'
PLUGINS=needs-example
EOF
missing_deps="$(plugin_missing_dependencies "$PROJECT_DIR" needs-example | paste -sd, -)"
assert_eq "missing dependency reported" "example" "$missing_deps"
assert_false "dependency validation fails" plugin_validate_dependencies "$PROJECT_DIR"
cat > "$PROJECT_DIR/craft.conf" << 'EOF'
PLUGINS=example,needs-example
EOF
assert_true "dependency validation passes" plugin_validate_dependencies "$PROJECT_DIR"

echo ""
echo "craft doctor plugin diagnostics"
DOCTOR_BIN="$TMPDIR/doctor-bin"
mkdir -p "$DOCTOR_BIN" "$TMPDIR/projects/doctor-ok" "$TMPDIR/projects/doctor-bad" "$CRAFT_ROOT/plugins/doctor-fail"
cat > "$DOCTOR_BIN/git" <<'EOF'
#!/usr/bin/env bash
echo "git version 2.0.0"
EOF
cat > "$DOCTOR_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh version 2.0.0"
EOF
cat > "$DOCTOR_BIN/jq" <<'EOF'
#!/usr/bin/env bash
echo "jq-1.7"
EOF
cat > "$DOCTOR_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
echo "tmux 3.4"
EOF
cat > "$DOCTOR_BIN/craft" <<'EOF'
#!/usr/bin/env bash
echo "craft stub"
EOF
chmod +x "$DOCTOR_BIN"/{git,gh,jq,tmux,craft}
cat > "$TMPDIR/projects/doctor-ok/craft.conf" <<'EOF'
PLUGINS=example,no-hooks
EOF
cat > "$CRAFT_ROOT/plugins/doctor-fail/hooks.sh" <<'EOF'
check_deps() {
    echo "doctor-fail missing tool"
    return 1
}
EOF
cat > "$TMPDIR/projects/doctor-bad/craft.conf" <<'EOF'
PLUGINS=doctor-fail
EOF
doctor_ok="$TMPDIR/doctor-ok.txt"
doctor_bad="$TMPDIR/doctor-bad.txt"
assert_true "doctor checks enabled plugins" bash -c "PATH='$DOCTOR_BIN':\$PATH CRAFT_ROOT='$CRAFT_ROOT' CRAFT_PROJECTS='$TMPDIR/projects' '$REPO_ROOT/bin/craft' doctor doctor-ok > '$doctor_ok' 2>&1"
assert_true "doctor reports plugin diagnostics" grep -q 'Plugin diagnostics (doctor-ok)' "$doctor_ok"
assert_true "doctor reports passing plugin check" grep -q 'example.*check_deps passed' "$doctor_ok"
assert_true "doctor reports no-hooks plugin" grep -q 'no-hooks.*no hooks' "$doctor_ok"
assert_false "doctor fails failing plugin check" bash -c "PATH='$DOCTOR_BIN':\$PATH CRAFT_ROOT='$CRAFT_ROOT' CRAFT_PROJECTS='$TMPDIR/projects' '$REPO_ROOT/bin/craft' doctor doctor-bad > '$doctor_bad' 2>&1"
assert_true "doctor shows failing plugin reason" grep -q 'doctor-fail missing tool' "$doctor_bad"

echo ""
echo "linear-sync cli contract"
LINEAR_ROOT="$TMPDIR/linear-craft"
LINEAR_PROJECT_DIR="$TMPDIR/linear-project"
LINEAR_BIN="$TMPDIR/linear-bin"
mkdir -p "$LINEAR_ROOT/plugins/linear-sync" "$LINEAR_PROJECT_DIR/queue"/{approved,in-progress,waiting,done,blocked,pending} "$LINEAR_BIN"
cp "$REPO_ROOT/plugins/linear-sync/hooks.sh" "$LINEAR_ROOT/plugins/linear-sync/hooks.sh"
cat > "$LINEAR_ROOT/plugins/linear-sync/plugin.conf" <<'EOF'
LINEAR_BIN="linear"
LINEAR_PROJECT="Craft Smoke"
LINEAR_TEAM=""
LINEAR_WORKSPACE=""
LINEAR_READY_STATE="unstarted"
LINEAR_IN_PROGRESS_STATE="started"
LINEAR_WAITING_STATE="started"
LINEAR_DONE_STATE="completed"
LINEAR_BLOCKED_STATE=""
LINEAR_ASSIGNEE=""
LINEAR_LABEL=""
EOF
cat > "$LINEAR_BIN/linear" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$TMPDIR/linear.log"
if [[ "\$*" == issue\\ query* ]]; then
  cat <<'JSON'
{
  "nodes": [
    {
      "identifier": "LIN-123",
      "title": "Fix sync path",
      "description": "Exercise current linear command shape",
      "priority": 2,
      "labels": {
        "nodes": [{"name":"craft"}]
      }
    }
  ]
}
JSON
fi
EOF
chmod +x "$LINEAR_BIN/linear"
cat > "$LINEAR_PROJECT_DIR/craft.conf" <<'EOF'
BRANCH_PREFIX="ed/"
EOF
(
    export CRAFT_ROOT="$LINEAR_ROOT" PROJECT_DIR="$LINEAR_PROJECT_DIR" PATH="$LINEAR_BIN:$PATH"
    source "$LINEAR_ROOT/plugins/linear-sync/hooks.sh"
    on_poll
)
assert_true "linear on_poll creates task" test -f "$LINEAR_PROJECT_DIR/queue/approved/task-001.md"
assert_true "linear uses current issue query command" grep -q '^issue query ' "$TMPDIR/linear.log"
assert_true "linear queries portable ready state type" grep -q -- '--state unstarted' "$TMPDIR/linear.log"
assert_file_contains "linear task id" "$LINEAR_PROJECT_DIR/queue/approved/task-001.md" "linear_id: LIN-123"
mv "$LINEAR_PROJECT_DIR/queue/approved/task-001.md" "$LINEAR_PROJECT_DIR/queue/in-progress/task-001.md"
(
    export CRAFT_ROOT="$LINEAR_ROOT" PROJECT_DIR="$LINEAR_PROJECT_DIR" PATH="$LINEAR_BIN:$PATH"
    source "$LINEAR_ROOT/plugins/linear-sync/hooks.sh"
    on_started --task-id task-001
    on_blocked --task-id task-001 --reason "needs input"
)
assert_true "linear uses current issue update command" grep -q '^issue update LIN-123 --state started$' "$TMPDIR/linear.log"
assert_true "linear uses current issue comment command" grep -q '^issue comment add LIN-123 --body Blocked by craft: needs input$' "$TMPDIR/linear.log"

echo ""
echo "devin helper contract"
DEVIN_BIN="$TMPDIR/devin-bin"
DEVIN_WORK="$TMPDIR/devin-work"
mkdir -p "$DEVIN_BIN" "$DEVIN_WORK/out"
cat > "$DEVIN_BIN/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"-X POST"* && "$args" == *"/v1/sessions"* ]]; then
  printf '%s\n' '{"session_id":"devin-test","url":"https://app.devin.ai/sessions/devin-test"}'
  exit 0
fi
if [[ "$args" == *"/v1/sessions/devin-test"* ]]; then
  cat <<'JSON'
{
  "status": "running",
  "status_enum": "blocked",
  "structured_output": {
    "summary": "Smoke complete",
    "markdown": "# Smoke complete"
  }
}
JSON
  exit 0
fi
echo "unexpected curl args: $args" >&2
exit 1
EOF
chmod +x "$DEVIN_BIN/curl"
cat > "$DEVIN_WORK/prompt.md" <<'EOF'
Return structured output.
EOF
cat > "$DEVIN_WORK/schema.json" <<'EOF'
{"type":"object","required":["summary","markdown"],"properties":{"summary":{"type":"string"},"markdown":{"type":"string"}}}
EOF
assert_true "devin accepts blocked response with structured output" bash -c "PATH='$DEVIN_BIN':\$PATH DEVIN_API_KEY=fake CRAFT_TASK_ID=/ '$REPO_ROOT/plugins/devin/scripts/delegate-to-devin' --prompt-file '$DEVIN_WORK/prompt.md' --schema-file '$DEVIN_WORK/schema.json' --output '$DEVIN_WORK/out/result.md' --poll-timeout 1 --poll-interval 1 > '$TMPDIR/devin.out' 2> '$TMPDIR/devin.err'"
assert_file_contains "devin writes markdown output" "$DEVIN_WORK/out/result.md" "# Smoke complete"
assert_true "devin prints pointer json" bash -c "jq -e '.session_id == \"devin-test\" and .summary == \"Smoke complete\"' '$TMPDIR/devin.out' >/dev/null"

echo ""
echo "plugin_queue_states"
states="$(plugin_queue_states "$PROJECT_DIR" | paste -sd, -)"
assert_eq "core plus plugin states" "drafts,pending,approved,in-progress,waiting,done,blocked,archive,extra-review,custom-review" "$states"

echo ""
echo "notify hook args"
source "$REPO_ROOT/bin/lib/queue.sh"
source "$REPO_ROOT/bin/lib/notify.sh"
QUEUE_STATES=(drafts pending approved in-progress waiting done blocked archive extra-review custom-review)
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
