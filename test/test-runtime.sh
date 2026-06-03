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
mkdir -p "$QUEUE_DIR"/{drafts,pending,approved,in-progress,waiting,done,blocked,archive,local-review}
mkdir -p "$PROJECT_DIR/tasks/task-123/.orchestrator"

cat > "$PROJECT_DIR/craft.conf" <<'EOF'
MULTIPLEXER=cmux
PLUGINS=
EOF

cat > "$QUEUE_DIR/in-progress/task-123.md" <<'EOF'
---
id: task-123
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
source "$REPO_ROOT/bin/lib/providers.sh"

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
assert_eq "start hook fired" "1" "$(grep -c '^on_stage_start ' "$hook_log")"

start_hooks_before_resume="$(grep -c '^on_stage_start ' "$hook_log")"
(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft" task stage resume task-123 --reason "agent surface recreated"
)
assert_eq "resume hook fired" "1" "$(grep -c '^on_stage_resume ' "$hook_log")"
assert_eq "resume does not fire start hook" "$start_hooks_before_resume" "$(grep -c '^on_stage_start ' "$hook_log")"
assert_eq "resume preserves stage" "implement" "$(task_field "$QUEUE_DIR/in-progress/task-123.md" stage)"

(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft" task stage advance task-123 --reason "next"
)
assert_eq "stage advance" "qa" "$(task_field "$QUEUE_DIR/in-progress/task-123.md" stage)"
assert_eq "end hook fired on transition" "1" "$(grep -c '^on_stage_end ' "$hook_log")"

(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft" task stage set task-123 pr_review --reason "open pr"
)
assert_true "stage projects queue state" test -f "$QUEUE_DIR/waiting/task-123.md"
assert_eq "stage projection updates status" "waiting" "$(task_field "$QUEUE_DIR/waiting/task-123.md" status)"
assert_eq "stage projection preserves stage" "pr_review" "$(task_field "$QUEUE_DIR/waiting/task-123.md" stage)"

(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft" task state set task-123 waiting \
        --stage pr_review \
        --reason "pr review" \
        --set pr=https://github.com/example/repo/pull/1 \
        --log "PR Review Started" \
        --log-body "Branch: refactor/runtime"
)
assert_true "task state moved file" test -f "$QUEUE_DIR/waiting/task-123.md"
assert_eq "task state updates status" "waiting" "$(task_field "$QUEUE_DIR/waiting/task-123.md" status)"
assert_eq "task state updates stage" "pr_review" "$(task_field "$QUEUE_DIR/waiting/task-123.md" stage)"
assert_eq "task state sets field" "https://github.com/example/repo/pull/1" "$(task_field "$QUEUE_DIR/waiting/task-123.md" pr)"
assert_true "task state work log" grep -q '^### PR Review Started — ' "$QUEUE_DIR/waiting/task-123.md"
assert_eq "task state hook fired" "2" "$(grep -c '^on_task_state_after ' "$hook_log")"

(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft" task state set task-123 in-progress --stage implement --reason "resume implementation"
)
assert_true "task state returns file" test -f "$QUEUE_DIR/in-progress/task-123.md"
assert_eq "state set suppresses stage queue sync" "in-progress" "$(task_field "$QUEUE_DIR/in-progress/task-123.md" status)"

(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft" task wait-team task-123 --reason "waiting on reviewer"
)
assert_eq "wait-team marker" "team" "$(task_field "$QUEUE_DIR/in-progress/task-123.md" waiting_on)"
assert_eq "wait-team reason" "waiting on reviewer" "$(task_field "$QUEUE_DIR/in-progress/task-123.md" waiting_reason)"
assert_eq "wait-team preserves stage" "implement" "$(task_field "$QUEUE_DIR/in-progress/task-123.md" stage)"
(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft" task unwait-team task-123
)
assert_eq "unwait clears marker" "" "$(task_field "$QUEUE_DIR/in-progress/task-123.md" waiting_on)"
assert_eq "unwait preserves stage" "implement" "$(task_field "$QUEUE_DIR/in-progress/task-123.md" stage)"

echo ""
echo "provider resume commands"
claude_resume_cmd="$(provider_task_resume_cmd claude "$TMPDIR/prompt.txt" "$PROJECT_DIR/tasks/task-123" "sonnet")"
codex_resume_cmd="$(provider_task_resume_cmd codex "$TMPDIR/prompt.txt" "$PROJECT_DIR/tasks/task-123" "gpt-5")"
assert_true "claude uses continue resume" bash -c "grep -q 'claude --continue' <<< \"\$1\"" _ "$claude_resume_cmd"
assert_true "codex uses interactive resume --last" bash -c "grep -q 'codex.*resume --last' <<< \"\$1\"" _ "$codex_resume_cmd"
assert_true "codex disables startup update prompt" \
    bash -c "grep -q -- '-c check_for_update_on_startup=false' <<< \"\$1\"" _ "$codex_resume_cmd"
assert_true "codex resume disables fast service tier" \
    bash -c "grep -q -- '-c service_tier=standard' <<< \"\$1\"" _ "$codex_resume_cmd"
assert_true "codex resume uses high reasoning" \
    bash -c "grep -q -- '-c model_reasoning_effort=high' <<< \"\$1\"" _ "$codex_resume_cmd"
assert_true "codex does not pass resume prompt as session id" \
    bash -c 'if grep -Fq "$2" <<< "$1"; then exit 1; fi' _ "$codex_resume_cmd" 'resume --last "$(cat'
assert_true "task run entrypoint uses craft command" \
    bash -c "source '$REPO_ROOT/bin/lib/providers.sh' && CRAFT_ROOT='$REPO_ROOT' provider_task_entry_cmd run task-123 /tmp/prompt /tmp/work claude opus | grep -q 'craft task run task-123'"
assert_true "task resume entrypoint uses craft command" \
    bash -c "source '$REPO_ROOT/bin/lib/providers.sh' && CRAFT_ROOT='$REPO_ROOT' provider_task_entry_cmd resume task-123 /tmp/prompt /tmp/work codex gpt-5 because | grep -q 'craft task resume task-123'"

cat > "$TMPDIR/bin/smoke-agent" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$TMPDIR/smoke-agent-args"
printf 'task=%s\nfile=%s\ndir=%s\n' "\${CRAFT_TASK_ID:-}" "\${CRAFT_TASK_FILE:-}" "\${CRAFT_TASK_DIR:-}" > "$TMPDIR/smoke-agent-env"
EOF
chmod +x "$TMPDIR/bin/smoke-agent"
cat > "$QUEUE_DIR/in-progress/task-run.md" <<'EOF'
---
id: task-run
status: in-progress
depends_on: []
repos: [craft]
branch: runtime/run
---

## Summary
Task run fixture.
EOF
mkdir -p "$PROJECT_DIR/tasks/task-run/.orchestrator"
printf 'run entry prompt\n' > "$TMPDIR/run-entry-prompt.txt"
start_hooks_before_run="$(grep -c '^on_stage_start ' "$hook_log")"
rm -f "$PROJECT_DIR/tasks/task-run/.orchestrator/events/pending/"*.json
(
    export CRAFT_HOOK_RUNNER="$hook_runner"
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft" task run task-run --prompt "$TMPDIR/run-entry-prompt.txt" --agent smoke-agent
)
assert_true "task run entrypoint injects prompt" grep -q 'run entry prompt' "$TMPDIR/smoke-agent-args"
assert_true "task run entrypoint exports task env" grep -q '^task=task-run$' "$TMPDIR/smoke-agent-env"
assert_eq "task run entrypoint starts workflow stage" "implement" "$(task_field "$QUEUE_DIR/in-progress/task-run.md" stage)"
assert_eq "task run entrypoint fires start hook locally" "$((start_hooks_before_run + 1))" "$(grep -c '^on_stage_start ' "$hook_log")"
assert_eq "task run stage event does not wake agent" "0" "$([[ -f "$FAKE_CMUX_STATE" ]] && jq '.sent | length' "$FAKE_CMUX_STATE" || echo 0)"

printf 'resume entry prompt\n' > "$TMPDIR/resume-entry-prompt.txt"
(
    export CRAFT_HOOK_RUNNER="$hook_runner"
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft" task resume task-123 --prompt "$TMPDIR/resume-entry-prompt.txt" --agent smoke-agent --reason "entrypoint resume"
)
assert_true "task resume entrypoint injects prompt" grep -q 'resume entry prompt' "$TMPDIR/smoke-agent-args"
assert_true "task resume entrypoint fires resume hook" grep -q '^on_stage_resume ' "$hook_log"

echo ""
echo "event queue"
assert_true "craft-mux session override resolves task pane" bash -c "cd '$PROJECT_DIR' && '$REPO_ROOT/bin/craft-mux' --session craft-project-task-123 exists task-123"
stage_events="$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event counts task-123)"
assert_true "stage changes publish events" bash -c "grep -q 'stage.changed:' <<< '$stage_events'"
rm -f "$PROJECT_DIR/tasks/task-123/.orchestrator/events/pending/"*.json
jq '.sent = []' "$FAKE_CMUX_STATE" > "$TMPDIR/cmux-reset.json" && mv "$TMPDIR/cmux-reset.json" "$FAKE_CMUX_STATE"
payload1="$TMPDIR/payload1.json"
payload2="$TMPDIR/payload2.json"
printf '{"body":"one"}\n' > "$payload1"
printf '{"body":"two"}\n' > "$payload2"
(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft" event enqueue task-123 --type pr_review --summary "review one" --json "$payload1" >/dev/null
    "$REPO_ROOT/bin/craft" event enqueue task-123 --type ci_status --summary "ci two" --json "$payload2" >/dev/null
)
assert_eq "duplicate wake suppressed" "2" "$(jq '.sent | length' "$FAKE_CMUX_STATE")"
assert_eq "wake is queue summary" "CRAFT_EVENTS task=task-123 pending=1 counts=pr_review:1" "$(jq -r '.sent[0].text' "$FAKE_CMUX_STATE")"
assert_eq "wake submits with newline" "true" "$(jq -r '.sent[1].text == "\n"' "$FAKE_CMUX_STATE")"
counts="$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event counts task-123)"
assert_eq "event counts" "pending=2 counts=ci_status:1,pr_review:1" "$counts"
filtered_counts="$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event counts task-123 --type ci_status --publisher cli)"
assert_eq "event counts filters by type and publisher" "pending=1 counts=ci_status:1" "$filtered_counts"
listed="$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event list task-123 --summary-contains two --limit 1)"
assert_eq "event list returns matching event" "ci_status" "$(jq -r '.[0].type' <<< "$listed")"
assert_eq "event list does not delete" "pending=2 counts=ci_status:1,pr_review:1" "$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event counts task-123)"
listed_id="$(jq -r '.[0].id' <<< "$listed")"
assert_true "event list includes id" test -n "$listed_id"
assert_eq "event ack by id" "acked=1" "$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event ack task-123 --id "$listed_id")"
taken="$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event take task-123 --type pr_review --limit 1)"
assert_eq "take returns one" "1" "$(jq 'length' <<< "$taken")"
assert_eq "publisher recorded" "cli" "$(jq -r '.[0].publisher' <<< "$taken")"
counts_after="$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event counts task-123)"
assert_eq "take deletes" "pending=0 counts=" "$counts_after"

rm -f "$PROJECT_DIR/tasks/task-123/.orchestrator/events/pending/"*.json
jq '.sent = []' "$FAKE_CMUX_STATE" > "$TMPDIR/cmux-reset.json" && mv "$TMPDIR/cmux-reset.json" "$FAKE_CMUX_STATE"
(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft" event notify-filter set task-123 --type ci_status >/dev/null
    "$REPO_ROOT/bin/craft" event enqueue task-123 --type pr_review --summary "muted by filter" --json "$payload1" >/dev/null
    "$REPO_ROOT/bin/craft" event enqueue task-123 --type ci_status --summary "matching filter" --json "$payload2" >/dev/null
)
assert_eq "notification filter stored" "ci_status" "$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event notify-filter get task-123 | jq -r '.types[0]')"
assert_eq "notification filter suppresses unmatched wake" "2" "$(jq '.sent | length' "$FAKE_CMUX_STATE")"
assert_eq "notification wake uses filtered counts" "CRAFT_EVENTS task=task-123 pending=1 counts=ci_status:1" "$(jq -r '.sent[0].text' "$FAKE_CMUX_STATE")"
assert_eq "notification filtered wake submits with newline" "true" "$(jq -r '.sent[1].text == "\n"' "$FAKE_CMUX_STATE")"
echo 1 > "$PROJECT_DIR/tasks/task-123/.orchestrator/events/last-notified-at"
jq '.sent = []' "$FAKE_CMUX_STATE" > "$TMPDIR/cmux-reset.json" && mv "$TMPDIR/cmux-reset.json" "$FAKE_CMUX_STATE"
runtime_event_notify_pending "$PROJECT_DIR" task-123 900 >/dev/null
assert_eq "notification reminder sends stale wake" "CRAFT_EVENTS task=task-123 pending=1 counts=ci_status:1" "$(jq -r '.sent[0].text' "$FAKE_CMUX_STATE")"
assert_eq "notification reminder submits with newline" "true" "$(jq -r '.sent[1].text == "\n"' "$FAKE_CMUX_STATE")"
runtime_event_notify_pending "$PROJECT_DIR" task-123 900 >/dev/null || true
assert_eq "notification reminder waits for interval" "2" "$(jq '.sent | length' "$FAKE_CMUX_STATE")"
assert_eq "ack by filter removes matching events only" "acked=1" "$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event ack task-123 --type ci_status)"
assert_eq "notification filter clear" "{}" "$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event notify-filter clear task-123 && "$REPO_ROOT/bin/craft" event notify-filter get task-123 | jq -c 'del(.ids,.types,.publishers,.summary_contains,.since,.before)')"
rm -f "$PROJECT_DIR/tasks/task-123/.orchestrator/events/pending/"*.json
(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft" task signal task-123 operator_signal --reason "operator requested action" >/dev/null
)
signalled="$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event take task-123 --type operator_signal --limit 1)"
assert_eq "task signal enqueues event" "operator_signal" "$(jq -r '.[0].type' <<< "$signalled")"
assert_eq "task signal reason" "operator requested action" "$(jq -r '.[0].payload.reason' <<< "$signalled")"
(
    cd "$PROJECT_DIR/tasks/task-123" || exit 1
    "$REPO_ROOT/bin/craft" event enqueue --type inferred_task --summary "inferred task" --json "$payload1" >/dev/null
)
assert_eq "event commands infer task from cwd" "pending=1 counts=inferred_task:1" "$(cd "$PROJECT_DIR/tasks/task-123" && "$REPO_ROOT/bin/craft" event counts --type inferred_task)"
assert_eq "event commands accept --task override" "pending=1 counts=inferred_task:1" "$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event counts --task task-123 --type inferred_task)"
assert_eq "event ack infers task from cwd" "acked=1" "$(cd "$PROJECT_DIR/tasks/task-123" && "$REPO_ROOT/bin/craft" event ack --type inferred_task)"

consume_hook="$TMPDIR/consume-hook"
cat > "$consume_hook" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "on_event" && " $* " == *" --event-type swallowed "* ]]; then
    printf 'consumed\n' > "${EVENT_CONSUME_FILE:?}"
fi
EOF
chmod +x "$consume_hook"
export CRAFT_HOOK_RUNNER="$consume_hook"
rm -f "$PROJECT_DIR/tasks/task-123/.orchestrator/events/pending/"*.json
(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft" event enqueue task-123 --type swallowed --summary "swallow me" --json "$payload1" >/dev/null
)
assert_eq "consumed event is not queued" "pending=0 counts=" "$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event counts task-123)"
export CRAFT_HOOK_RUNNER="$hook_runner"

echo ""
echo "surface metadata and fake cmux"
(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft-mux" open task-123 pr --url https://github.com/example/repo/pull/1 --label "PR" --owner test --stage pr_review >/dev/null
)
assert_eq "surface registered" "https://github.com/example/repo/pull/1" "$(jq -r '.windows[0].workspaces[0].panes[].surfaces[] | select(.metadata["craft:semantic"] == "pr").metadata["craft:url"]' "$FAKE_CMUX_STATE")"
assert_eq "browser opened in right pane" "pane:2" "$(jq -r '.windows[0].workspaces[0].panes[] | select(.surfaces[]?.url == "https://github.com/example/repo/pull/1").ref' "$FAKE_CMUX_STATE")"
(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft-mux" open task-123 build --url https://build.example/task-123 --label "Build" --owner test --stage qa >/dev/null
)
assert_eq "second browser reuses right pane" "pane:2" "$(jq -r '.windows[0].workspaces[0].panes[] | select(.surfaces[]?.url == "https://build.example/task-123").ref' "$FAKE_CMUX_STATE")"
assert_eq "right-side browser tabs do not add splits" "2" "$(jq '[.windows[0].workspaces[0].panes[].ref] | length' "$FAKE_CMUX_STATE")"
assert_eq "non-agent surface records right placement" "right" "$(jq -r '.windows[0].workspaces[0].panes[].surfaces[] | select(.metadata["craft:semantic"] == "build").metadata["craft:placement"]' "$FAKE_CMUX_STATE")"
source "$REPO_ROOT/bin/lib/mux-cmux.sh"
_cmux_ensure_surface "workspace:1" "dashboard" "browser" "dashboard" --title "dashboard" --url "http://127.0.0.1:27434" >/dev/null
assert_eq "dashboard browser opens in left pane" "pane:1" "$(jq -r '.windows[0].workspaces[0].panes[] | select(.surfaces[]?.url == "http://127.0.0.1:27434").ref' "$FAKE_CMUX_STATE")"
assert_eq "dashboard surface records left placement" "left" "$(jq -r '.windows[0].workspaces[0].panes[].surfaces[] | select(.metadata["craft:semantic"] == "dashboard").metadata["craft:placement"]' "$FAKE_CMUX_STATE")"
tmp_json="$TMPDIR/surfaces.json"
jq '
  .windows[0].workspaces += [{
    ref: "workspace:project",
    title: "craft-project",
    metadata: {
      "craft:schema-version": "1",
      "craft:project-id": "project",
      "craft:project-dir": "/tmp/project"
    },
    panes: [{
      ref: "pane:50",
      surfaces: [{
        ref:"surface:50",
        type:"terminal",
        title:"orchestrator",
        metadata: {
          "craft:semantic": "orchestrator",
          "craft:type": "terminal",
          "craft:purpose": "orchestrator",
          "craft:title": "orchestrator",
          "craft:placement": "left"
        }
      }]
    }]
  }]
' "$FAKE_CMUX_STATE" > "$tmp_json" && mv "$tmp_json" "$FAKE_CMUX_STATE"
project_dashboard="$(_cmux_ensure_surface "workspace:project" "dashboard" "browser" "dashboard" --title "dashboard" --url "http://127.0.0.1:27434" --placement left)"
project_architect="$(_cmux_ensure_surface "workspace:project" "architect" "terminal" "architect" --title "architect" --command "echo architect" --agent "codex" --placement right)"
assert_eq "project dashboard shares orchestrator pane" "pane:50" "$(jq -r '.windows[0].workspaces[] | select(.ref == "workspace:project").panes[] | select(.surfaces[]?.ref == "'"$project_dashboard"'").ref' "$FAKE_CMUX_STATE")"
assert_eq "project architect opens right pane" "true" "$(jq -r '.windows[0].workspaces[] | select(.ref == "workspace:project").panes[] | select(.surfaces[]?.ref == "'"$project_architect"'").ref != "pane:50"' "$FAKE_CMUX_STATE")"
assert_eq "project architect uses create command" "echo architect" "$(jq -r '.windows[0].workspaces[] | select(.ref == "workspace:project").panes[].surfaces[] | select(.ref == "'"$project_architect"'").command' "$FAKE_CMUX_STATE")"
project_pr="$(mux_project_browser_open_untracked "$PROJECT_DIR" "https://github.com/example/repo/pull/9" "pr:repo#9")"
project_architect_pane="$(jq -r --arg s "$project_architect" '.windows[0].workspaces[] | select(.ref == "workspace:project").panes[] | select(.surfaces[]?.ref == $s).ref' "$FAKE_CMUX_STATE")"
project_pr_pane="$(jq -r --arg s "$project_pr" '.windows[0].workspaces[] | select(.ref == "workspace:project").panes[] | select(.surfaces[]?.ref == $s).ref' "$FAKE_CMUX_STATE")"
project_pr_semantic="$(jq -r --arg s "$project_pr" '[.windows[0].workspaces[] | select(.ref == "workspace:project").panes[].surfaces[] | select(.ref == $s) | (.metadata["craft:semantic"] // "null")] | .[0] // "missing"' "$FAKE_CMUX_STATE")"
assert_eq "project browser opens untracked in right pane" "$project_architect_pane" "$project_pr_pane"
assert_eq "project browser does not write semantic metadata" "null" "$project_pr_semantic"
jq '.focused = "surface:previous"' "$FAKE_CMUX_STATE" > "$tmp_json" && mv "$tmp_json" "$FAKE_CMUX_STATE"
_cmux_ensure_dashboard_surface "workspace:project" "$PROJECT_DIR" "http://127.0.0.1:27434" >/dev/null
assert_eq "dashboard ensure does not steal focus by default" "surface:previous" "$(jq -r '.focused' "$FAKE_CMUX_STATE")"
CMUX_FOCUS_DASHBOARD=1 _cmux_ensure_dashboard_surface "workspace:project" "$PROJECT_DIR" "http://127.0.0.1:27434" >/dev/null
assert_eq "project dashboard is focused by default" "$project_dashboard" "$(jq -r '.focused' "$FAKE_CMUX_STATE")"
jq '
  .windows[0].workspaces[] |=
    if .ref == "workspace:project" then
      .panes[0].surfaces += [
        {ref:"surface:dashboard-duplicate", type:"browser", title:"dashboard", url:"http://localhost:27434/"}
      ]
    else . end
' "$FAKE_CMUX_STATE" > "$tmp_json" && mv "$tmp_json" "$FAKE_CMUX_STATE"
_cmux_ensure_dashboard_surface "workspace:project" "$PROJECT_DIR" "http://127.0.0.1:27434" >/dev/null
assert_eq "dashboard ensure prunes duplicate browsers" "1" "$(jq '[.windows[0].workspaces[] | select(.ref == "workspace:project").panes[].surfaces[] | select(.type == "browser" and (.url // "" | startswith("http://localhost:27434") or startswith("http://127.0.0.1:27434")))] | length' "$FAKE_CMUX_STATE")"
jq '
  .windows[0].workspaces += [{
    ref: "workspace:adopt",
    title: "craft-launch-project",
    metadata: {},
    panes: [{
      ref: "pane:adopt",
      surfaces: [{
        ref:"surface:adopt",
        type:"terminal",
        title:"launcher",
        metadata:{}
      }]
    }]
  }]
' "$FAKE_CMUX_STATE" > "$tmp_json" && mv "$tmp_json" "$FAKE_CMUX_STATE"
CMUX_WORKSPACE_ID=workspace:adopt CMUX_SURFACE_ID=surface:adopt \
    mux_adopt_current_orchestrator_workspace adopted "$PROJECT_DIR" >/dev/null
assert_eq "current cmux workspace adopted for orchestrator" "adopted" "$(jq -r '.windows[0].workspaces[] | select(.ref == "workspace:adopt").metadata["craft:project-id"]' "$FAKE_CMUX_STATE")"
assert_eq "current cmux surface recorded as orchestrator" "orchestrator" "$(jq -r '.windows[0].workspaces[] | select(.ref == "workspace:adopt").panes[].surfaces[] | select(.ref == "surface:adopt").metadata["craft:semantic"]' "$FAKE_CMUX_STATE")"
workspace_count_before="$(jq '[.windows[0].workspaces[]] | length' "$FAKE_CMUX_STATE")"
CMUX_WORKSPACE_ID=workspace:adopt CMUX_SURFACE_ID=surface:adopt CRAFT_INNER_SESSION=1 \
    ensure_session adopted "$PROJECT_DIR" >/dev/null
assert_eq "inner cmux ensure reuses current workspace" "$workspace_count_before" "$(jq '[.windows[0].workspaces[]] | length' "$FAKE_CMUX_STATE")"
unset CMUX_WORKSPACE_ID CMUX_SURFACE_ID CRAFT_INNER_SESSION PROJECT_NAME SESSION
jq '
  .windows[0].workspaces += [{
    id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    ref: "workspace:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    title: "craft-launch-uuid",
    metadata: {},
    panes: [{
      ref: "pane:bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
      surfaces: [{
        id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        ref:"surface:bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        type:"terminal",
        title:"launcher",
        metadata:{}
      }]
    }]
  }]
' "$FAKE_CMUX_STATE" > "$tmp_json" && mv "$tmp_json" "$FAKE_CMUX_STATE"
assert_true "surface existence accepts bare uuid surface id" \
    bash -c "source '$REPO_ROOT/bin/lib/mux-cmux.sh'; _cmux_surface_exists workspace:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
jq '
  .windows[0].workspaces[0].metadata["craft:surface:architect"] = {
    surface_id: "surface:42",
    type: "terminal",
    purpose: "architect",
    title: "architect"
  }
  | .windows[0].workspaces[0].panes[1].surfaces += [{ref:"surface:42", type:"terminal", title:"architect", metadata:{}}]
' "$FAKE_CMUX_STATE" > "$tmp_json" && mv "$tmp_json" "$FAKE_CMUX_STATE"
surface_count_before="$(jq '[.windows[0].workspaces[0].panes[].surfaces[]] | length' "$FAKE_CMUX_STATE")"
_cmux_ensure_surface "workspace:1" "architect" "terminal" "architect" --title "architect" --command "echo architect" --agent "codex" >/dev/null
assert_eq "legacy architect metadata migrates to surface metadata" "architect" "$(jq -r '.windows[0].workspaces[0].panes[].surfaces[] | select(.ref == "surface:42").metadata["craft:semantic"]' "$FAKE_CMUX_STATE")"
assert_eq "legacy architect workspace metadata is cleared" "null" "$(jq -r '.windows[0].workspaces[0].metadata["craft:surface:architect"] // null' "$FAKE_CMUX_STATE")"
assert_eq "architect adoption does not create surface" "$surface_count_before" "$(jq '[.windows[0].workspaces[0].panes[].surfaces[]] | length' "$FAKE_CMUX_STATE")"

(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft-mux" focus task-123 pr >/dev/null
)
assert_eq "focus uses current cmux surface metadata" "surface:2" "$(jq -r '.focused' "$FAKE_CMUX_STATE")"
workspace_state="$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft-mux" workspace-state task-123 agent)"
assert_eq "workspace state reports attached task" "false" "$(jq -r '.detached' <<< "$workspace_state")"
assert_eq "workspace state reports agent surface" "true" "$(jq -r '.surface_exists' <<< "$workspace_state")"
(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft-mux" focus task-123 agent >/dev/null
)
assert_eq "task agent focus uses cmux metadata" "surface:1" "$(jq -r '.focused' "$FAKE_CMUX_STATE")"
jq '
  .windows[0].workspaces += [{
    ref: "workspace:11111111-1111-1111-1111-111111111111",
    title: "craft-project-task-detached",
    attached: false,
    detached: true,
    metadata: {
      "craft:schema-version": "1",
      "craft:project-id": "project",
      "craft:task-id": "task-detached"
    },
    panes: [{
      ref: "pane:11111111-1111-1111-1111-111111111113",
      surfaces: [{
        ref:"surface:11111111-1111-1111-1111-111111111112",
        type:"terminal",
        title:"task-detached",
        metadata: {
          "craft:semantic": "agent",
          "craft:type": "terminal",
          "craft:purpose": "agent",
          "craft:title": "task-detached"
        }
      }]
    }]
  }]
' "$FAKE_CMUX_STATE" > "$tmp_json" && mv "$tmp_json" "$FAKE_CMUX_STATE"
detached_state="$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft-mux" workspace-state task-detached agent)"
assert_eq "workspace state reports detached task" "true" "$(jq -r '.detached' <<< "$detached_state")"
(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft-mux" focus task-detached agent --attach >/dev/null
)
assert_eq "attach focus uses restored agent surface" "surface:11111111-1111-1111-1111-111111111112" "$(jq -r '.focused' "$FAKE_CMUX_STATE")"

assert_false "unknown surface is not adopted" bash -c "cd '$PROJECT_DIR' && '$REPO_ROOT/bin/craft-mux' focus task-123 terminal"

jq '
  .windows[0].workspaces += [{
    ref: "workspace:send-fail",
    title: "craft-project-task-send-fail",
    metadata: {
      "craft:schema-version": "1",
      "craft:project-id": "project",
      "craft:task-id": "task-send-fail"
    },
    panes: [{
      ref: "pane:send-fail",
      surfaces: [{
        ref:"surface:send-fail",
        type:"terminal",
        title:"task-send-fail",
        metadata:{}
      }]
    }]
  }]
' "$FAKE_CMUX_STATE" > "$tmp_json" && mv "$tmp_json" "$FAKE_CMUX_STATE"
assert_false "agent resume reports send failure" \
    bash -c "export FAKE_CMUX_FAIL_SEND=1; source '$REPO_ROOT/bin/lib/mux-cmux.sh'; _cmux_ensure_surface workspace:send-fail agent terminal agent --title task-send-fail --command 'echo resume'"
assert_eq "failed resume does not record agent metadata" "0" \
    "$(jq '[.windows[0].workspaces[] | select(.ref == "workspace:send-fail").panes[].surfaces[] | select(.metadata["craft:semantic"] == "agent")] | length' "$FAKE_CMUX_STATE")"

echo ""
echo "remote task workspace creation"
mkdir -p "$PROJECT_DIR/tasks/task-remote/.orchestrator"
export CMUX_WORKSPACE_ID="workspace:remote"
export CMUX_REMOTE_DAEMON_SLOT="ssh-test-slot"
export USER="tester"
source "$REPO_ROOT/bin/lib/mux-cmux.sh"
remote_session="$(ensure_task_session project task-remote "$PROJECT_DIR/tasks/task-remote" "Remote task")"
unset CMUX_WORKSPACE_ID CMUX_REMOTE_DAEMON_SLOT
assert_eq "remote task returns structured session" "craft-project-task-remote" "$remote_session"
remote_workspace_ref="$(_mux_ws_ref "$remote_session")"
assert_eq "remote task resolves workspace ref" "workspace:2" "$remote_workspace_ref"
assert_false "remote task does not write task-session mapping" test -f "$PROJECT_DIR/tasks/task-remote/.orchestrator/task-session.json"
assert_eq "remote task uses cmux ssh workspace" "craft-project-task-remote · Remote task" "$(jq -r '.windows[0].workspaces[] | select(.metadata["craft:task-id"] == "task-remote").title' "$FAKE_CMUX_STATE")"
assert_eq "remote task metadata records dir" "$PROJECT_DIR/tasks/task-remote" "$(jq -r '.windows[0].workspaces[] | select(.metadata["craft:task-id"] == "task-remote").metadata["craft:task-dir"]' "$FAKE_CMUX_STATE")"
CMUX_CLOSE_WORKSPACE_SYNC=1 mux_replace_orchestrator_workspace project "$PROJECT_DIR" "CRAFT_INNER_SESSION=1 exec orchestrator" >/dev/null
assert_eq "orchestrator workspace restart closes old project workspace" "0" "$(jq '[.windows[0].workspaces[] | select(.ref == "workspace:project")] | length' "$FAKE_CMUX_STATE")"
assert_eq "orchestrator workspace restart creates replacement" "1" "$(jq '[.windows[0].workspaces[] | select(.metadata["craft:project-id"] == "project" and (.metadata["craft:task-id"] // "") == "")] | length' "$FAKE_CMUX_STATE")"
assert_eq "orchestrator workspace restart sends launch command" "CRAFT_INNER_SESSION=1 exec orchestrator" "$(jq -r '.sent[-2].text' "$FAKE_CMUX_STATE")"
assert_eq "orchestrator workspace restart submits launch command" "true" "$(jq -r '.sent[-1].text == "\n"' "$FAKE_CMUX_STATE")"
unset CMUX_CLOSE_WORKSPACE_SYNC
(
    cd "$PROJECT_DIR" || exit 1
    CRAFT_ROOT="$REPO_ROOT" "$REPO_ROOT/plugins/craft-dashboard/scripts/set-task-state" task-remote in-progress >/dev/null
)
assert_eq "task state script uses provider status helper" "in-progress" "$(jq -r '.windows[0].workspaces[] | select(.metadata["craft:task-id"] == "task-remote").status.task_state.value' "$FAKE_CMUX_STATE")"
assert_false "task state script reports provider status failure" bash -c "cd '$PROJECT_DIR' && CRAFT_ROOT='$REPO_ROOT' FAKE_CMUX_FAIL_SET_STATUS=1 '$REPO_ROOT/plugins/craft-dashboard/scripts/set-task-state' task-remote blocked"

echo ""
echo "provider commands"
source "$REPO_ROOT/bin/lib/workflow.sh"
source "$REPO_ROOT/bin/lib/providers.sh"
assert_true "hyphenated provider env var is safe" bash -c "source '$REPO_ROOT/bin/lib/providers.sh' && SMOKE_AGENT_APPROVAL_MODE=never provider_task_cmd smoke-agent /tmp/prompt /tmp/work >/dev/null"
assert_true "task agent model becomes provider flag" bash -c "source '$REPO_ROOT/bin/lib/providers.sh' && provider_task_cmd claude /tmp/prompt /tmp/work opus | grep -q -- '--model opus'"
codex_task_cmd="$(provider_task_cmd codex /tmp/prompt /tmp/work)"
assert_true "codex task defaults to gpt-5.5" bash -c "grep -q -- '--model gpt-5.5' <<< \"\$1\"" _ "$codex_task_cmd"
assert_true "codex task defaults to high reasoning" bash -c "grep -q -- '-c model_reasoning_effort=high' <<< \"\$1\"" _ "$codex_task_cmd"
assert_true "codex task defaults to fast off" bash -c "grep -q -- '-c service_tier=standard' <<< \"\$1\"" _ "$codex_task_cmd"
assert_true "codex task model override wins" bash -c "source '$REPO_ROOT/bin/lib/providers.sh' && provider_task_cmd codex /tmp/prompt /tmp/work gpt-5 | grep -q -- '--model gpt-5'"
assert_true "codex service tier override wins" bash -c "source '$REPO_ROOT/bin/lib/providers.sh' && CODEX_SERVICE_TIER=fast provider_task_cmd codex /tmp/prompt /tmp/work | grep -q -- '-c service_tier=fast'"
assert_true "codex reasoning override wins" bash -c "source '$REPO_ROOT/bin/lib/providers.sh' && CODEX_REASONING_EFFORT=xhigh provider_task_cmd codex /tmp/prompt /tmp/work | grep -q -- '-c model_reasoning_effort=xhigh'"
DISCOVERY_PROJECT="$TMPDIR/discovery-project"
mkdir -p "$DISCOVERY_PROJECT/queue"/{approved,pending,in-progress,waiting,done,blocked,archive}
cat > "$DISCOVERY_PROJECT/craft.conf" <<'EOF'
PLUGINS=planning
DEFAULT_AGENT=codex
EOF
cat > "$DISCOVERY_PROJECT/queue/in-progress/task-discovery.md" <<'EOF'
---
id: task-discovery
status: in-progress
workflow: discovery
---
EOF
load_provider_config "$DISCOVERY_PROJECT"
assert_eq "workflow default agent selected" "claude" "$(task_agent "$DISCOVERY_PROJECT/queue/in-progress/task-discovery.md" "$DISCOVERY_PROJECT")"
assert_eq "workflow default model selected" "opus" "$(task_agent_model "$DISCOVERY_PROJECT/queue/in-progress/task-discovery.md" "$DISCOVERY_PROJECT")"

echo ""
echo "dashboard command"
rm -rf "$PROJECT_DIR/.state/dashboard"
rm -f "$PROJECT_DIR"/.orchestrator/dashboard.* "$PROJECT_DIR/dashboard-invoked"
for _ in $(seq 1 20); do
    CRAFT_DASHBOARD_PORT=$((30000 + RANDOM % 20000))
    if ! curl -sS -o /dev/null -m 1 "http://127.0.0.1:${CRAFT_DASHBOARD_PORT}/healthz" 2>/dev/null; then
        break
    fi
done
export CRAFT_DASHBOARD_PORT
export DASHBOARD_CMD='printf "%s %s\n" "$PROJECT_DIR" "$CRAFT_DASHBOARD_PORT" > "$PROJECT_DIR/dashboard-invoked"'
source "$REPO_ROOT/bin/lib/mux-cmux.sh"
CMUX_WORKSPACE_ID=workspace:dashboard-test CMUX_SURFACE_ID=surface:dashboard-test \
    _cmux_ensure_dashboard_server "$PROJECT_DIR" >/dev/null
unset CMUX_WORKSPACE_ID CMUX_SURFACE_ID
for _ in $(seq 1 20); do
    [[ -f "$PROJECT_DIR/dashboard-invoked" ]] && break
    sleep 0.1
done
assert_eq "dashboard command invoked" "$PROJECT_DIR $CRAFT_DASHBOARD_PORT" "$(cat "$PROJECT_DIR/dashboard-invoked")"

echo ""
echo "────────────────────────────"
echo "$TESTS_RUN tests: $TESTS_PASSED passed, $TESTS_FAILED failed"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
