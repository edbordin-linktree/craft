# diffhub — Diffhub UI and local-review comment ingestion.

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/hook-runtime.sh
source "${CRAFT_ROOT:-$(cd "$PLUGIN_DIR/../.." && pwd -P)}/bin/lib/hook-runtime.sh"

_diffhub_worktree() {
    craft_hook_primary_worktree_for_task "$TASK_DIR" 2>/dev/null || true
}

on_stage_start() {
    craft_hook_parse_stage_args "$@"
    case "$STAGE" in
        local_review)
            local worktree
            worktree="$(_diffhub_worktree)"
            [[ -n "$worktree" ]] || return 0
            (
                cd "$worktree" || exit 0
                if [[ ! -s .orchestrator/diffhub.url ]]; then
                    "$PLUGIN_DIR/scripts/launch-diffhub" --repo "$worktree" >/dev/null 2>&1 || true
                fi
            )
            craft_hook_start_helper_once "$worktree" "$PLUGIN_DIR/scripts/babysit-diffhub" babysit-diffhub --worktree "$worktree"
            ;;
        cleanup|blocked|complete)
            local worktree
            worktree="$(_diffhub_worktree)"
            [[ -n "$worktree" ]] || return 0
            "$PLUGIN_DIR/scripts/cleanup-review-stage" --repo "$worktree" >/dev/null 2>&1 || true
            ;;
    esac
}

on_stage_end() {
    craft_hook_parse_stage_args "$@"
    [[ "$STAGE" == "local_review" ]] || return 0
    local worktree
    worktree="$(_diffhub_worktree)"
    [[ -n "$worktree" ]] || return 0
    "$PLUGIN_DIR/scripts/cleanup-review-stage" --repo "$worktree" >/dev/null 2>&1 || true
}
