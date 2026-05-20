# orchestrator-skills/hooks.sh — Lifecycle hooks for the orchestrator-skills plugin
#
# Project skills and commands are exposed through this plugin's project/ tree.
# Craft core syncs those assets into each enabled project as symlinks.

# Resolve this plugin's directory.
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Dependency check ---
check_deps() {
    return 0
}

# --- Hooks ---

# Called once by `craft plugin add` after the plugin is symlinked into the
# project. Interactively offers to set DEFAULT_AGENT=codex (this plugin's
# coding-agent assumption — the work-task flow is designed around Codex doing
# the coding and a Claude sub-agent doing cross-model review). Idempotent;
# respects user choice if they decline or set something else.
on_install() {
    local project_dir="${1:-$PROJECT_DIR}"
    local conf="$project_dir/craft.conf"
    [[ -f "$conf" ]] || { echo "[orchestrator-skills] on_install: no craft.conf at $conf" >&2; return 1; }

    local current=""
    if grep -qE '^[[:space:]]*DEFAULT_AGENT=' "$conf"; then
        current="$(grep -E '^[[:space:]]*DEFAULT_AGENT=' "$conf" | head -1 \
            | sed -E 's/^[[:space:]]*DEFAULT_AGENT=//; s/^"//; s/"$//')"
    fi

    if [[ "$current" == "codex" ]]; then
        echo "[orchestrator-skills] DEFAULT_AGENT=codex already set"
    else
        # `claude` is craft's template default — treat it as "default, not a
        # deliberate user choice" so we offer the change with default Y. Anything
        # else is a real user-set value and we default to leaving it alone.
        local prompt default
        if [[ -z "$current" ]] || [[ "$current" == "claude" ]]; then
            if [[ -z "$current" ]]; then
                prompt="Set DEFAULT_AGENT=codex so the orchestrator launches Codex as the coding agent? [Y/n]"
            else
                prompt="Change DEFAULT_AGENT from 'claude' (default) to 'codex' for the coding agent? [Y/n]"
            fi
            default="y"
        else
            prompt="Change DEFAULT_AGENT from '$current' to 'codex'? [y/N]"
            default="n"
        fi

        local answer
        if [[ -t 0 ]]; then
            read -rp "[orchestrator-skills] $prompt " answer
            answer="${answer:-$default}"
        else
            answer="$default"
            echo "[orchestrator-skills] (non-interactive) defaulting to '$default': $prompt"
        fi

        case "${answer,,}" in
            y|yes)
                if [[ -n "$current" ]]; then
                    if sed --version 2>/dev/null | grep -q GNU; then
                        sed -i -E "s|^[[:space:]]*DEFAULT_AGENT=.*$|DEFAULT_AGENT=codex|" "$conf"
                    else
                        sed -i "" -E "s|^[[:space:]]*DEFAULT_AGENT=.*$|DEFAULT_AGENT=codex|" "$conf"
                    fi
                    echo "[orchestrator-skills] updated DEFAULT_AGENT=codex (was '$current')"
                else
                    printf '\n# Added by orchestrator-skills/on_install\nDEFAULT_AGENT=codex\n' >> "$conf"
                    echo "[orchestrator-skills] appended DEFAULT_AGENT=codex to craft.conf"
                fi
                ;;
            *)
                if [[ -n "$current" ]]; then
                    echo "[orchestrator-skills] keeping DEFAULT_AGENT=$current"
                else
                    echo "[orchestrator-skills] leaving DEFAULT_AGENT unset — the orchestrator will use 'claude' per the template default"
                    echo "[orchestrator-skills] note: this plugin's work-task flow is designed assuming Codex is the coding agent"
                fi
                ;;
        esac
    fi

    if ! grep -qE '^[[:space:]]*DASHBOARD_CMD=' "$conf"; then
        cat >> "$conf" <<'EOF'

# Added by orchestrator-skills/on_install
DASHBOARD_CMD='cd "$CRAFT_ROOT/plugins/orchestrator-skills/dashboard" && bun server.tsx --project "$PROJECT_DIR" --port "$CRAFT_DASHBOARD_PORT"'
EOF
        echo "[orchestrator-skills] appended DASHBOARD_CMD for the web dashboard"
    fi
}

# Called on every orchestrator poll. Project asset syncing is handled by Craft
# core before this hook runs.
on_poll() {
    return 0
}

# Called once when a task starts (moves to in-progress). Currently a no-op; the
# project-scope install at on_poll covers both architect and task agents.
# Reserved for future per-task skill scoping if we want it.
on_started() {
    return 0
}

_parse_stage_args() {
    STAGE=""
    TASK_ID=""
    TASK_DIR=""
    TASK_FILE=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stage) STAGE="${2:-}"; shift 2 ;;
            --task-id) TASK_ID="${2:-}"; shift 2 ;;
            --task-dir) TASK_DIR="${2:-}"; shift 2 ;;
            --task-file) TASK_FILE="${2:-}"; shift 2 ;;
            --project-dir) shift 2 ;;
            --status|--reason) shift 2 ;;
            *) shift ;;
        esac
    done
}

_parse_task_state_args() {
    TASK_ID=""
    TASK_DIR=""
    TASK_FILE=""
    STATUS=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --task-id) TASK_ID="${2:-}"; shift 2 ;;
            --task-dir) TASK_DIR="${2:-}"; shift 2 ;;
            --task-file) TASK_FILE="${2:-}"; shift 2 ;;
            --status) STATUS="${2:-}"; shift 2 ;;
            --project-dir|--reason) shift 2 ;;
            *) shift ;;
        esac
    done
}

_primary_worktree_for_task() {
    local task_dir="$1" candidate
    [[ -d "$task_dir" ]] || return 1
    for candidate in "$task_dir"/*; do
        [[ -d "$candidate/.orchestrator" ]] && { echo "$candidate"; return 0; }
    done
    return 1
}

_task_frontmatter_field() {
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

_pidfile_alive() {
    local pidfile="$1" pid
    [[ -f "$pidfile" ]] || return 1
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

_start_task_helper_once() {
    local worktree="$1" name="$2"
    shift 2
    [[ -d "$worktree" ]] || return 0
    _pidfile_alive "$worktree/.orchestrator/$name.pid" && return 0
    (
        cd "$worktree" || exit 0
        "$PLUGIN_DIR/scripts/run-bg" "$name" "$@" >/dev/null 2>&1 || true
    )
}

_cleanup_task_runtime_surfaces() {
    local task_id="$1" worktree="$2"
    [[ -n "$task_id" && -d "$worktree" ]] || return 0
    (
        cd "$worktree" || exit 0
        "$CRAFT_ROOT/bin/craft" surface close "$task_id" diffhub-review >/dev/null 2>&1 || true
        "$CRAFT_ROOT/bin/craft" surface close "$task_id" github-pr >/dev/null 2>&1 || true
        "$CRAFT_ROOT/bin/craft" surface close "$task_id" devin-session >/dev/null 2>&1 || true
    )
}

_start_local_review_runtime() {
    local worktree="$1"
    [[ -f "$worktree/.orchestrator/diffhub.url" ]] || return 0
    _start_task_helper_once "$worktree" babysit-diffhub --worktree "$worktree"
}

_start_pr_review_runtime() {
    local task_id="$1" task_file="$2" worktree="$3"
    local pr_url
    [[ -n "$task_id" && -n "$task_file" && -d "$worktree" ]] || return 0
    pr_url="$(_task_frontmatter_field "$task_file" pr 2>/dev/null || true)"
    [[ -n "$pr_url" ]] || return 0

    "$PLUGIN_DIR/scripts/cleanup-review-stage" --repo "$worktree" >/dev/null 2>&1 || true
    "$PLUGIN_DIR/scripts/open-pr-surface" "$pr_url" --repo "$worktree" >/dev/null 2>&1 || true
    _start_task_helper_once "$worktree" watch-pr --pr "$pr_url" --worktree "$worktree"
    (
        cd "$worktree" || exit 0
        "$PLUGIN_DIR/scripts/show-build-status" "$pr_url" >/dev/null 2>&1 || true
    )
}

on_stage_after() {
    _parse_stage_args "$@"
    case "$STAGE" in
        local_review)
            local worktree
            worktree="$(_primary_worktree_for_task "$TASK_DIR" 2>/dev/null || true)"
            [[ -n "$worktree" ]] || return 0
            _start_local_review_runtime "$worktree"
            ;;
        pr_review)
            local worktree
            worktree="$(_primary_worktree_for_task "$TASK_DIR" 2>/dev/null || true)"
            [[ -n "$worktree" ]] || return 0
            _start_pr_review_runtime "$TASK_ID" "$TASK_FILE" "$worktree"
            ;;
        cleanup|blocked|complete)
            local worktree
            worktree="$(_primary_worktree_for_task "$TASK_DIR" 2>/dev/null || true)"
            [[ -n "$worktree" ]] || return 0
            "$PLUGIN_DIR/scripts/cleanup-review-stage" --repo "$worktree" >/dev/null 2>&1 || true
            "$PLUGIN_DIR/scripts/cleanup-pr-stage" --repo "$worktree" >/dev/null 2>&1 || true
            _cleanup_task_runtime_surfaces "$TASK_ID" "$worktree"
            ;;
    esac
}

on_task_state_after() {
    _parse_task_state_args "$@"
    [[ -n "$TASK_ID" && -n "$STATUS" ]] || return 0
    "$PLUGIN_DIR/scripts/set-task-state" "$TASK_ID" "$STATUS" >/dev/null 2>&1 || true
}
