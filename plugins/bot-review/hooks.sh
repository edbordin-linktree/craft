# bot-review — Start automated local branch review during local_review.

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/hook-runtime.sh
source "${CRAFT_ROOT:-$(cd "$PLUGIN_DIR/../.." && pwd -P)}/bin/lib/hook-runtime.sh"

on_stage_start() {
    craft_hook_parse_stage_args "$@"
    [[ "$STAGE" == "local_review" ]] || return 0
    local worktree
    worktree="$(craft_hook_primary_worktree_for_task "$TASK_DIR" 2>/dev/null || true)"
    [[ -n "$worktree" ]] || return 0
    craft_hook_start_helper_once "$worktree" "$PLUGIN_DIR/scripts/review-pr" review-pr --worktree "$worktree"
}

on_stage_end() {
    craft_hook_parse_stage_args "$@"
    [[ "$STAGE" == "local_review" || "$NEXT_STAGE" == "blocked" || "$NEXT_STAGE" == "complete" ]] || return 0
    local worktree
    worktree="$(craft_hook_primary_worktree_for_task "$TASK_DIR" 2>/dev/null || true)"
    [[ -n "$worktree" ]] || return 0
    craft_hook_stop_helper "$worktree" review-pr
}
