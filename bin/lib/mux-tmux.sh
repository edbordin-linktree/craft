#!/usr/bin/env bash
# tmux.sh — Tmux pane management for the craft orchestrator

# Session name for the orchestrator
TMUX_SESSION="craft"

# Ensure the tmux session exists, with orchestrator + architect windows
# Returns the session name
ensure_session() {
    local project_name="$1"
    local project_dir="$2"  # optional — used to cd the architect window
    local session="${TMUX_SESSION}-${project_name}"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        tmux new-session -d -s "$session" -n "orchestrator"
        # Disable monitor-activity on the orchestrator window so dashboard refreshes
        # don't trigger tmux activity alerts
        tmux set-option -t "${session}:orchestrator" monitor-activity off 2>/dev/null || true
    fi

    # Ensure architect window exists — an agent session pre-loaded with project context
    if ! tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null | grep -q '^architect$'; then
        tmux new-window -t "${session}:" -n "architect"
        if [[ -n "${project_dir:-}" ]]; then
            local skill_file="${project_dir}/.claude/commands/init-architect.md"
            local architect_agent="${ARCHITECT_AGENT:-claude}"
            local architect_agent_model="${ARCHITECT_AGENT_MODEL:-}"
            local cmd
            cmd=$(provider_architect_cmd "$architect_agent" "$skill_file" "$project_dir" "$architect_agent_model")
            # Use send-keys so the agent runs inside an interactive shell.
            # Passing the command to new-window runs it as the window's initial
            # process, which breaks TUI input (arrow keys, etc.) for agents
            # like codex that use interactive terminal frameworks.
            tmux send-keys -t "${session}:architect" "$cmd" Enter
        fi
        tmux select-window -t "${session}:orchestrator"
    fi

    echo "$session"
}

# ensure_task_session — tmux has no native workspace concept, so per-task
# isolation collapses into "give the task its own window inside the project
# session". Return the project session title; spawn_task_pane will then create
# a window named after the task id, same behaviour as today.
ensure_task_session() {
    local project_name="$1"
    echo "${TMUX_SESSION}-${project_name}"
}

# Create a new window for a task and run the agent in it
# Returns the window ID
spawn_task_pane() {
    local session="$1" task_id="$2" prompt_file="$3" work_dir="$4"
    local agent="${5:-claude}"
    local agent_model="${6:-}"

    local cmd
    cmd=$(provider_task_cmd "$agent" "$prompt_file" "$work_dir" "$agent_model")

    # Create window with a shell first, then send the command via send-keys.
    # This ensures the agent runs inside an interactive shell pty, so TUI
    # input (arrow keys, etc.) works if the operator jumps into the pane.
    local window_id
    window_id=$(tmux new-window -t "${session}:" -n "$task_id" -P -F '#{window_id}')
    tmux send-keys -t "${session}:${task_id}" "$cmd" Enter

    echo "$window_id"
}

# Check if a task pane is still running
# Returns 0 if running, 1 if finished
pane_is_running() {
    local session="$1" task_id="$2"

    if tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null | grep -q "^${task_id}$"; then
        # Check if the process in the pane is still running
        local pane_pid
        pane_pid=$(tmux list-panes -t "${session}:${task_id}" -F '#{pane_pid}' 2>/dev/null | head -1)
        if [[ -n "$pane_pid" ]] && kill -0 "$pane_pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Kill a task pane
kill_task_pane() {
    local session="$1" task_id="$2"
    tmux kill-window -t "${session}:${task_id}" 2>/dev/null || true
}

# Update the orchestrator pane with status info
update_orchestrator_display() {
    local session="$1" status_text="$2"

    # Write status to a temp file that the orchestrator pane reads
    local status_file="/tmp/craft-${session}-status"
    echo "$status_text" > "$status_file"
}

# --- Generic primitives for skills (not used by the orchestrator daemon) ---

# Spawn a new tmux window named <name> in <session>, cd into <cwd>, run <cmd>.
# Idempotent: if the named window already exists, no-op.
mux_spawn_named_pane() {
    local session="$1" name="$2" cwd="$3" cmd="$4"

    if tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null | grep -q "^${name}$"; then
        return 0
    fi

    tmux new-window -t "${session}:" -n "$name" >/dev/null
    # Start with a shell, then send the command via send-keys so the agent
    # runs inside an interactive pty (TUI input works for the operator).
    tmux send-keys -t "${session}:${name}" "cd '$cwd' && $cmd" Enter
}

# Send text + Enter to the named pane.
mux_send_to_pane() {
    local session="$1" name="$2" text="$3"
    tmux send-keys -t "${session}:${name}" "$text" Enter
}

# Returns 0 if the named pane exists, 1 otherwise.
mux_pane_exists() {
    local session="$1" name="$2"
    tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null | grep -q "^${name}$"
}

# Kill the named pane.
mux_kill_named_pane() {
    local session="$1" name="$2"
    tmux kill-window -t "${session}:${name}" 2>/dev/null || true
}

mux_surface_open() {
    echo "surface_unsupported: tmux provider does not manage browser surfaces" >&2
    return 3
}

mux_surface_focus() {
    echo "surface_unsupported: tmux provider does not manage browser surfaces" >&2
    return 3
}

mux_task_workspace_state() {
    local _project_dir="$1" task_id="$2" surface_id="${3:-agent}"
    jq -n \
        --arg task_id "$task_id" \
        --arg surface_ref "$surface_id" \
        '{task_id:$task_id, exists:true, attached:true, detached:false, surface_ref:$surface_ref, surface_exists:true}'
}

mux_surface_close() {
    echo "surface_unsupported: tmux provider does not manage browser surfaces" >&2
    return 3
}

mux_task_status_set() {
    return 0
}
