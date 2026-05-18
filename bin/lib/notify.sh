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
    hook_runner="${notify_dir%/lib}/run-hook.sh"                  # $CRAFT_ROOT/bin/run-hook.sh
    if [[ -x "$hook_runner" ]]; then
        "$hook_runner" "$@" --project-dir "$PROJECT_DIR" 2>/dev/null || true
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

# Notify that a task has started
notify_started() {
    local task_id="$1"
    _run_hook on_started --task-id "$task_id"
}

# Notify about a blocked task
notify_blocked() {
    local task_id="$1" reason="$2"
    _tmux_bell
    _run_hook on_blocked --task-id "$task_id" --reason "$reason"
}

# Notify about a completed task
notify_done() {
    local task_id="$1" pr_url="$2"
    _tmux_bell
    _run_hook on_done --task-id "$task_id" --pr-url "$pr_url"
}

# Notify about a task waiting for review
notify_waiting() {
    local task_id="$1"
    _tmux_bell
    _run_hook on_waiting --task-id "$task_id"
}

# Notify about milestone completion
notify_milestone() {
    local milestone="$1"
    _tmux_bell
    _run_hook on_milestone --milestone "$milestone"
}
