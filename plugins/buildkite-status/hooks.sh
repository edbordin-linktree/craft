# buildkite-status — Optional Buildkite status browser surface.

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/hook-runtime.sh
source "${CRAFT_ROOT:-$(cd "$PLUGIN_DIR/../.." && pwd -P)}/bin/lib/hook-runtime.sh"

_bk_status_pr_url() {
    [[ -n "$TASK_FILE" ]] || return 1
    craft_hook_task_frontmatter_field "$TASK_FILE" pr 2>/dev/null || true
}

_bk_status_surface_title() {
    local pr_url="$1"
    if [[ "$pr_url" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
        printf 'bk:%s#%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
        return 0
    fi
    return 1
}

_bk_status_close_surface() {
    local pr_url="$1" title surface
    [[ -n "$pr_url" ]] || return 0
    command -v cmux >/dev/null || return 0
    title="$(_bk_status_surface_title "$pr_url" 2>/dev/null || true)"
    [[ -n "$title" ]] || return 0
    surface="$(cmux tree --all --json 2>/dev/null \
        | jq -r --arg title "$title" '
            .windows[].workspaces[].panes[].surfaces[]
            | select(.title == $title)
            | .ref' 2>/dev/null \
        | head -1)"
    [[ -n "$surface" ]] || return 0
    cmux close-surface --surface "$surface" >/dev/null 2>&1 || true
}

on_stage_start() {
    craft_hook_parse_stage_args "$@"
    [[ "$STAGE" == "pr_review" || "$STAGE" == "complete" ]] || return 0
    local worktree pr_url
    worktree="$(craft_hook_primary_worktree_for_task "$TASK_DIR" 2>/dev/null || true)"
    [[ -n "$worktree" && -n "$TASK_FILE" ]] || return 0
    pr_url="$(_bk_status_pr_url)"
    [[ -n "$pr_url" ]] || return 0
    (
        cd "$worktree" || exit 0
        "$PLUGIN_DIR/scripts/show-build-status" "$pr_url" >/dev/null 2>&1 || true
    )
}

on_stage_end() {
    craft_hook_parse_stage_args "$@"
    [[ "$STAGE" == "pr_review" ]] || return 0
    local pr_url
    pr_url="$(_bk_status_pr_url)"
    _bk_status_close_surface "$pr_url"
}
