# diffhub — Diffhub UI and local-review comment ingestion.

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/hook-runtime.sh
source "${CRAFT_ROOT:-$(cd "$PLUGIN_DIR/../.." && pwd -P)}/bin/lib/hook-runtime.sh"
# shellcheck source=bin/lib/task-runtime.sh
source "${CRAFT_ROOT:-$(cd "$PLUGIN_DIR/../.." && pwd -P)}/bin/lib/task-runtime.sh"

_diffhub_worktree() {
    craft_hook_primary_worktree_for_task "$TASK_DIR" 2>/dev/null || true
}

_diffhub_ready() {
    local worktree="$1" url
    url="$(cat "$worktree/.orchestrator/diffhub.url" 2>/dev/null || true)"
    [[ -n "$url" ]] || return 1
    command -v curl >/dev/null 2>&1 || return 1
    curl -fsS "${url%/}/api/health" >/dev/null 2>&1
}

_diffhub_open_surface() {
    local worktree="$1" url
    [[ -n "${TASK_ID:-}" ]] || return 1
    url="$(cat "$worktree/.orchestrator/diffhub.url" 2>/dev/null || true)"
    [[ -n "$url" ]] || return 1
    orchestrator_surface_open "$worktree" "$TASK_ID" diffhub-review \
        --url "$url" --label "diffhub" --owner diffhub --stage local_review --url-match exact >/dev/null
}

_diffhub_start_local_review() {
    local restart="${1:-0}" worktree
    worktree="$(_diffhub_worktree)"
    [[ -n "$worktree" ]] || return 0
    [[ -n "${TASK_ID:-}" ]] || return 0

    if [[ "$restart" == "1" ]]; then
        # Resume is entered from the task agent terminal. Stop stale helper PIDs
        # from older Craft builds before recreating them under this task PTY.
        craft_hook_stop_helper "$worktree" babysit-diffhub
        craft_hook_stop_helper "$worktree" diffhub
    fi
    if ! _diffhub_ready "$worktree"; then
        craft_hook_start_helper_once "$worktree" "$PLUGIN_DIR/scripts/start-local-review" diffhub-local-review --repo "$worktree"
        return 0
    fi
    _diffhub_open_surface "$worktree" || true
    craft_hook_start_helper_once "$worktree" "$PLUGIN_DIR/scripts/babysit-diffhub" babysit-diffhub --worktree "$worktree"
}

on_stage_start() {
    craft_hook_parse_stage_args "$@"
    case "$STAGE" in
        local_review)
            _diffhub_start_local_review
            ;;
        cleanup|blocked|complete)
            local worktree
            worktree="$(_diffhub_worktree)"
            [[ -n "$worktree" ]] || return 0
            "$PLUGIN_DIR/scripts/cleanup-review-stage" --repo "$worktree" >/dev/null 2>&1 || true
            ;;
    esac
}

on_stage_resume() {
    craft_hook_parse_stage_args "$@"
    [[ "$STAGE" == "local_review" ]] || return 0
    _diffhub_start_local_review 1
}

on_stage_end() {
    craft_hook_parse_stage_args "$@"
    [[ "$STAGE" == "local_review" ]] || return 0
    local worktree
    worktree="$(_diffhub_worktree)"
    [[ -n "$worktree" ]] || return 0
    "$PLUGIN_DIR/scripts/cleanup-review-stage" --repo "$worktree" >/dev/null 2>&1 || true
}
