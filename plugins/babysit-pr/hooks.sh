# babysit-pr — GitHub PR surface and PR event watcher.

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/hook-runtime.sh
source "${CRAFT_ROOT:-$(cd "$PLUGIN_DIR/../.." && pwd -P)}/bin/lib/hook-runtime.sh"

_pr_review_worktree() {
    craft_hook_primary_worktree_for_task "$TASK_DIR" 2>/dev/null || true
}

_pr_review_cleanup() {
    local worktree="$1"
    [[ -d "$worktree" ]] || return 0
    craft_hook_stop_helper "$worktree" watch-pr
}

_pr_review_start() {
    local worktree="$1" pr_url="$2"
    [[ -n "$worktree" && -n "$pr_url" ]] || return 0
    "$PLUGIN_DIR/scripts/open-pr-surface" "$pr_url" --repo "$worktree" >/dev/null 2>&1 || true
    craft_hook_start_helper_once "$worktree" "$PLUGIN_DIR/scripts/watch-pr" watch-pr --pr "$pr_url" --worktree "$worktree"
}

on_stage_start() {
    craft_hook_parse_stage_args "$@"
    case "$STAGE" in
        pr_review)
            local worktree pr_url
            worktree="$(_pr_review_worktree)"
            [[ -n "$worktree" && -n "$TASK_FILE" ]] || return 0
            pr_url="$(craft_hook_task_frontmatter_field "$TASK_FILE" pr 2>/dev/null || true)"
            _pr_review_start "$worktree" "$pr_url"
            ;;
        cleanup|blocked|complete)
            local worktree
            worktree="$(_pr_review_worktree)"
            [[ -n "$worktree" ]] || return 0
            _pr_review_cleanup "$worktree"
            ;;
    esac
}

on_stage_end() {
    craft_hook_parse_stage_args "$@"
    [[ "$STAGE" == "pr_review" ]] || return 0
    local worktree
    worktree="$(_pr_review_worktree)"
    [[ -n "$worktree" ]] || return 0
    _pr_review_cleanup "$worktree"
}

on_task_state_after() {
    craft_hook_parse_task_state_args "$@"
    [[ "$STATUS" == "waiting" && -n "$TASK_FILE" ]] || return 0
    [[ "$(craft_hook_task_frontmatter_field "$TASK_FILE" stage 2>/dev/null || true)" == "pr_review" ]] || return 0
    local worktree pr_url
    worktree="$(_pr_review_worktree)"
    pr_url="$(craft_hook_task_frontmatter_field "$TASK_FILE" pr 2>/dev/null || true)"
    _pr_review_start "$worktree" "$pr_url"
}
