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

export CRAFT_ROOT="$TMPDIR/craft"
PROJECT_DIR="$TMPDIR/project"
QUEUE_DIR="$PROJECT_DIR/queue"
mkdir -p "$CRAFT_ROOT/bin/lib" "$CRAFT_ROOT/plugins/example/fragments/stages" "$CRAFT_ROOT/plugins/example/fragments/events" "$CRAFT_ROOT/plugins/example/stages" "$CRAFT_ROOT/plugins/example/events"
mkdir -p "$PROJECT_DIR/tasks/task-123" "$PROJECT_DIR/tasks/task-124" "$QUEUE_DIR"/{drafts,pending,approved,in-progress,waiting,done,blocked,archive}
ln -s "$REPO_ROOT/bin/lib/queue.sh" "$CRAFT_ROOT/bin/lib/queue.sh"
ln -s "$REPO_ROOT/bin/lib/plugins.sh" "$CRAFT_ROOT/bin/lib/plugins.sh"
ln -s "$REPO_ROOT/bin/lib/workflow.sh" "$CRAFT_ROOT/bin/lib/workflow.sh"
ln -s "$REPO_ROOT/bin/lib/runtime.sh" "$CRAFT_ROOT/bin/lib/runtime.sh"
ln -s "$REPO_ROOT/workflows" "$CRAFT_ROOT/workflows"
ln -s "$REPO_ROOT/stages" "$CRAFT_ROOT/stages"
ln -s "$REPO_ROOT/plugins/babysit-pr" "$CRAFT_ROOT/plugins/babysit-pr"

cat > "$PROJECT_DIR/craft.conf" <<'EOF'
PLUGINS=example,babysit-pr
EOF

cat > "$CRAFT_ROOT/plugins/example/plugin.conf" <<'EOF'
# stage insertion is declared in plugins/example/stages/*.md
EOF

cat > "$CRAFT_ROOT/plugins/example/fragments/stages/qa.md" <<'EOF'
Run the example plugin QA fragment.
EOF

cat > "$CRAFT_ROOT/plugins/example/stages/watching_prod_deploy.md" <<'EOF'
---
insert: after:pr_review
events: deploy.ready
---
Watch the production deploy before completion.
EOF

cat > "$CRAFT_ROOT/plugins/example/events/deploy.ready.md" <<'EOF'
---
---
Deploy watcher events use this contract.
EOF

cat > "$CRAFT_ROOT/plugins/example/fragments/events/deploy.ready.md" <<'EOF'
---
---
Example plugin adds deploy event metadata.
EOF

cat > "$QUEUE_DIR/in-progress/task-123.md" <<'EOF'
---
id: task-123
type: pr
status: in-progress
workflow: standard-pr
workflow_options:
  retries: 2
depends_on: []
repos: [craft]
branch: feat/workflow
---

## Summary
Workflow fixture.
EOF

cat > "$QUEUE_DIR/in-progress/task-124.md" <<'EOF'
---
id: task-124
type: pr
status: in-progress
workflow: standard-pr
workflow_options:
  retries: 1
depends_on: []
repos: [craft]
branch: feat/workflow-disabled
---

## Summary
Workflow fixture.
EOF

cat > "$QUEUE_DIR/in-progress/task-125.md" <<'EOF'
---
id: task-125
type: pr
status: in-progress
workflow: ../../evil
depends_on: []
repos: [craft]
branch: feat/bad-workflow
---

## Summary
Workflow path escape fixture.
EOF

source "$CRAFT_ROOT/bin/lib/workflow.sh"
source "$CRAFT_ROOT/bin/lib/runtime.sh"

echo "workflow options"
options="$(workflow_task_options_json "$QUEUE_DIR/in-progress/task-123.md")"
assert_eq "typed number option" "2" "$(jq -r '.retries' <<< "$options")"

echo ""
echo "workflow stage resolution"
stages="$(workflow_resolve_stages "$PROJECT_DIR" "$QUEUE_DIR/in-progress/task-123.md" | paste -sd, -)"
assert_eq "plugin stage inserted" "implement,qa,pr_review,watching_prod_deploy,complete" "$stages"

PROJECT_NO_PLUGINS="$TMPDIR/project-no-plugins"
mkdir -p "$PROJECT_NO_PLUGINS/tasks/task-124" "$PROJECT_NO_PLUGINS/queue"/{drafts,pending,approved,in-progress,waiting,done,blocked,archive}
cat > "$PROJECT_NO_PLUGINS/craft.conf" <<'EOF'
PLUGINS=
EOF
cp "$QUEUE_DIR/in-progress/task-124.md" "$PROJECT_NO_PLUGINS/queue/in-progress/task-124.md"
disabled_stages="$(workflow_resolve_stages "$PROJECT_NO_PLUGINS" "$PROJECT_NO_PLUGINS/queue/in-progress/task-124.md" | paste -sd, -)"
assert_eq "standard stages without plugins" "implement,qa,pr_review,complete" "$disabled_stages"
assert_false "workflow path escape rejected" workflow_resolve_stages "$PROJECT_DIR" "$QUEUE_DIR/in-progress/task-125.md"

mv "$CRAFT_ROOT/plugins/example/stages/watching_prod_deploy.md" "$CRAFT_ROOT/plugins/example/stages/watching_prod_deploy.md.good"
cat > "$CRAFT_ROOT/plugins/example/stages/watching_prod_deploy.md" <<'EOF'
---
insert: sideways:pr_review
---
Bad plugin stage.
EOF
assert_false "invalid plugin insertion rejected" workflow_resolve_stages "$PROJECT_DIR" "$QUEUE_DIR/in-progress/task-123.md"
mv "$CRAFT_ROOT/plugins/example/stages/watching_prod_deploy.md.good" "$CRAFT_ROOT/plugins/example/stages/watching_prod_deploy.md"

echo ""
echo "workflow prompt rendering"
prompt="$TMPDIR/prompt.md"
workflow_render_prompt "$PROJECT_DIR" "$QUEUE_DIR/in-progress/task-123.md" task-123.md > "$prompt"
assert_true "prompt includes workflow options" grep -q '"retries":2' "$prompt"
assert_true "prompt includes plugin fragment" grep -q 'Run the example plugin QA fragment.' "$prompt"
assert_true "prompt includes plugin stage" grep -q 'Watch the production deploy before completion.' "$prompt"
assert_true "prompt includes event contract" grep -q 'Deploy watcher events use this contract.' "$prompt"
assert_true "prompt includes event fragment" grep -q 'Example plugin adds deploy event metadata.' "$prompt"
assert_true "prompt includes context preflight" grep -q 'docs/plan.md' "$prompt"
assert_true "prompt includes dependency guard" grep -q 'craft task stage block <task-id>' "$prompt"
assert_true "prompt includes worktree setup" grep -q 'Set up repository worktrees' "$prompt"
assert_true "prompt includes open PR state guard" grep -q 'gh pr list --state open' "$prompt"
assert_true "prompt includes PR creation" grep -q 'create a draft PR' "$prompt"
assert_true "prompt includes review thread resolution" grep -q 'resolveReviewThread' "$prompt"

cli_prompt="$TMPDIR/cli-prompt.md"
(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" workflow render task-123 > "$cli_prompt")
assert_true "craft workflow render includes resolved stages" grep -q 'Resolved stages:' "$cli_prompt"
assert_true "craft workflow render includes plugin stage" grep -q 'Watch the production deploy before completion.' "$cli_prompt"

echo ""
echo "runtime stage validation"
assert_true "set plugin stage when enabled" runtime_stage_set "$PROJECT_DIR" task-123 watching_prod_deploy "watch deploy"
assert_false "reject plugin stage when disabled" runtime_stage_set "$PROJECT_NO_PLUGINS" task-124 watching_prod_deploy "watch deploy"
runtime_stage_set "$PROJECT_DIR" task-123 pr_review "review" >/dev/null
assert_true "stage metadata projects pr_review queue" test -f "$QUEUE_DIR/waiting/task-123.md"
assert_eq "stage metadata projected status" "waiting" "$(task_field "$QUEUE_DIR/waiting/task-123.md" status)"
assert_eq "advance uses resolved plugin stage" "watching_prod_deploy" "$(runtime_stage_advance "$PROJECT_DIR" task-123 "next")"
assert_false "reject unknown stage" runtime_stage_set "$PROJECT_DIR" task-123 no_such_stage "bad"
assert_true "terminal blocked stage is explicit escape" runtime_stage_set "$PROJECT_DIR" task-123 blocked "blocked" blocked
runtime_stage_set "$PROJECT_DIR" task-123 complete "done" >/dev/null
assert_true "complete stage projects done queue" test -f "$QUEUE_DIR/done/task-123.md"
assert_false "advance stops at final happy-path stage" runtime_stage_advance "$PROJECT_DIR" task-123 "next"

echo ""
echo "────────────────────────────"
echo "$TESTS_RUN tests: $TESTS_PASSED passed, $TESTS_FAILED failed"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
