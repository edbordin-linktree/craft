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
assert_true "codex uses resume --last" bash -c "grep -q 'codex.*resume --last' <<< \"\$1\"" _ "$codex_resume_cmd"

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
assert_eq "duplicate wake suppressed" "1" "$(jq '.sent | length' "$FAKE_CMUX_STATE")"
assert_eq "wake is queue summary" "CRAFT_EVENTS task=task-123 pending=1 counts=pr_review:1" "$(jq -r '.sent[0].text' "$FAKE_CMUX_STATE")"
counts="$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event counts task-123)"
assert_eq "event counts" "pending=2 counts=ci_status:1,pr_review:1" "$counts"
taken="$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event take task-123 --type pr_review --limit 1)"
assert_eq "take returns one" "1" "$(jq 'length' <<< "$taken")"
assert_eq "publisher recorded" "cli" "$(jq -r '.[0].publisher' <<< "$taken")"
counts_after="$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event counts task-123)"
assert_eq "take deletes" "pending=1 counts=ci_status:1" "$counts_after"
(
    cd "$PROJECT_DIR" || exit 1
    "$REPO_ROOT/bin/craft" task signal task-123 operator_signal --reason "operator requested action" >/dev/null
)
signalled="$(cd "$PROJECT_DIR" && "$REPO_ROOT/bin/craft" event take task-123 --type operator_signal --limit 1)"
assert_eq "task signal enqueues event" "operator_signal" "$(jq -r '.[0].type' <<< "$signalled")"
assert_eq "task signal reason" "operator requested action" "$(jq -r '.[0].payload.reason' <<< "$signalled")"

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
assert_eq "orchestrator workspace restart sends launch command" "CRAFT_INNER_SESSION=1 exec orchestrator" "$(jq -r '.sent[-1].text' "$FAKE_CMUX_STATE")"
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
for _ in $(seq 1 20); do
    CRAFT_DASHBOARD_PORT=$((30000 + RANDOM % 20000))
    if ! curl -sS -o /dev/null -m 1 "http://127.0.0.1:${CRAFT_DASHBOARD_PORT}/healthz" 2>/dev/null; then
        break
    fi
done
export CRAFT_DASHBOARD_PORT
export DASHBOARD_CMD='printf "%s %s\n" "$PROJECT_DIR" "$CRAFT_DASHBOARD_PORT" > "$PROJECT_DIR/dashboard-invoked"'
source "$REPO_ROOT/bin/lib/mux-cmux.sh"
_cmux_ensure_dashboard_server "$PROJECT_DIR" >/dev/null
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
