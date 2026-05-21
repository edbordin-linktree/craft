#!/usr/bin/env bash
# hook-runtime.sh — Shared helpers for plugin lifecycle hooks.

craft_hook_parse_stage_args() {
    STAGE=""
    PREVIOUS_STAGE=""
    NEXT_STAGE=""
    TASK_ID=""
    TASK_DIR=""
    TASK_FILE=""
    STATUS=""
    REASON=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stage) STAGE="${2:-}"; shift 2 ;;
            --previous-stage) PREVIOUS_STAGE="${2:-}"; shift 2 ;;
            --next-stage) NEXT_STAGE="${2:-}"; shift 2 ;;
            --task-id) TASK_ID="${2:-}"; shift 2 ;;
            --task-dir) TASK_DIR="${2:-}"; shift 2 ;;
            --task-file) TASK_FILE="${2:-}"; shift 2 ;;
            --status) STATUS="${2:-}"; shift 2 ;;
            --reason) REASON="${2:-}"; shift 2 ;;
            --project-dir|--workflow|--workflow-options-json) shift 2 ;;
            *) shift ;;
        esac
    done
}

craft_hook_parse_task_state_args() {
    TASK_ID=""
    TASK_DIR=""
    TASK_FILE=""
    STATUS=""
    REASON=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --task-id) TASK_ID="${2:-}"; shift 2 ;;
            --task-dir) TASK_DIR="${2:-}"; shift 2 ;;
            --task-file) TASK_FILE="${2:-}"; shift 2 ;;
            --status) STATUS="${2:-}"; shift 2 ;;
            --reason) REASON="${2:-}"; shift 2 ;;
            --project-dir) shift 2 ;;
            *) shift ;;
        esac
    done
}

craft_hook_primary_worktree_for_task() {
    local task_dir="$1" candidate
    [[ -d "$task_dir" ]] || return 1
    for candidate in "$task_dir"/*; do
        [[ -d "$candidate/.orchestrator" ]] && { echo "$candidate"; return 0; }
    done
    return 1
}

craft_hook_task_frontmatter_field() {
    local task_file="$1" field="$2"
    [[ -f "$task_file" ]] || return 1
    awk -v field="$field" '
        NR == 1 && $0 == "---" { in_fm = 1; next }
        in_fm && $0 == "---" { exit }
        in_fm && $0 ~ ("^" field ":") {
            sub("^" field ":[[:space:]]*", "")
            gsub(/^"|"$/, "")
            print
            exit
        }
    ' "$task_file"
}

craft_hook_start_helper_once() {
    local worktree="$1" helper="$2" name="$3"
    shift 3
    [[ -d "$worktree" ]] || return 0
    (cd "$worktree" && "$CRAFT_ROOT/bin/run-bg" status "$name" >/dev/null 2>&1) && return 0
    (
        cd "$worktree" || exit 0
        "$CRAFT_ROOT/bin/run-bg" --name "$name" "$helper" "$@" >/dev/null 2>&1 || true
    )
}

craft_hook_stop_helper() {
    local worktree="$1" name="$2"
    [[ -d "$worktree" ]] || return 0
    (
        cd "$worktree" || exit 0
        "$CRAFT_ROOT/bin/run-bg" stop "$name" >/dev/null 2>&1 || true
    )
}
