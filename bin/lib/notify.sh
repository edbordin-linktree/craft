#!/usr/bin/env bash
# notify.sh — Notification helpers for the craft orchestrator
#
# Dispatches lifecycle events to the plugin system and optionally plays
# a tmux bell for attention.

# Run a plugin hook. The dispatcher now lives at $CRAFT_ROOT/bin/run-hook.sh
# (plugins are a shared library at $CRAFT_ROOT/plugins/, not per-project).
_run_hook() {
    local notify_dir hook_runner
    notify_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # $CRAFT_ROOT/bin/lib
    hook_runner="${CRAFT_HOOK_RUNNER:-${notify_dir%/lib}/run-hook.sh}" # $CRAFT_ROOT/bin/run-hook.sh
    if [[ -x "$hook_runner" ]]; then
        local args=("$@")
        local has_project_dir=false
        local arg
        for arg in "${args[@]}"; do
            if [[ "$arg" == "--project-dir" ]]; then
                has_project_dir=true
                break
            fi
        done
        if ! $has_project_dir && [[ -n "${PROJECT_DIR:-}" ]]; then
            args+=(--project-dir "$PROJECT_DIR")
        fi
        "$hook_runner" "${args[@]}" 2>/dev/null || true
    fi
}

# Ring the bell on this pane's TTY so tmux highlights the window
_tmux_bell() {
    if [[ -n "${TMUX_PANE:-}" ]]; then
        local pane_tty
        pane_tty=$(tmux display-message -t "$TMUX_PANE" -p '#{pane_tty}' 2>/dev/null)
        if [[ -n "$pane_tty" ]]; then
            printf '\a' > "$pane_tty"
        fi
    else
        printf '\a'
    fi
}

_build_task_hook_args() {
    local task_id="$1"
    local task_file="${2:-}"
    local pr_url="${3:-}"

    if [[ -z "$pr_url" && -n "$task_file" && -f "$task_file" ]]; then
        pr_url="$(task_field "$task_file" "pr")"
    fi

    TASK_HOOK_ARGS=(--project-dir "$PROJECT_DIR" --task-id "$task_id")
    if [[ -n "$task_file" ]]; then
        TASK_HOOK_ARGS+=(--task-file "$task_file")
    fi
    local task_dir="$PROJECT_DIR/tasks/$task_id"
    if [[ -d "$task_dir" ]]; then
        TASK_HOOK_ARGS+=(--task-dir "$task_dir")
    fi
    if [[ -n "$pr_url" ]]; then
        TASK_HOOK_ARGS+=(--pr-url "$pr_url")
    fi
}

# Notify that a task has started
notify_started() {
    local task_id="$1" task_file="${2:-}"
    _build_task_hook_args "$task_id" "$task_file"
    _run_hook on_started "${TASK_HOOK_ARGS[@]}"
}

# Notify about a blocked task
notify_blocked() {
    local task_id="$1" reason="$2" task_file="${3:-}"
    _tmux_bell
    _build_task_hook_args "$task_id" "$task_file"
    _run_hook on_blocked "${TASK_HOOK_ARGS[@]}" --reason "$reason"
}

# Notify about a completed task
notify_done() {
    local task_id="$1" pr_url="${2:-}" task_file="${3:-}"
    _tmux_bell
    _build_task_hook_args "$task_id" "$task_file" "$pr_url"
    _run_hook on_done "${TASK_HOOK_ARGS[@]}"
}

# Notify about a task waiting for review
notify_waiting() {
    local task_id="$1" task_file="${2:-}"
    _tmux_bell
    _build_task_hook_args "$task_id" "$task_file"
    _run_hook on_waiting "${TASK_HOOK_ARGS[@]}"
}

# Notify about milestone completion
notify_milestone() {
    local milestone="$1"
    _tmux_bell
    _run_hook on_milestone --milestone "$milestone"
}
