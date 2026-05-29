#!/usr/bin/env bash
# linear-sync — Syncs Linear issues into craft queue, pushes status back
#
# Inbound: on_poll pulls "Ready" issues into queue/approved/ as task files
# Outbound: on_done/on_blocked/on_waiting update Linear issue state

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "$PLUGIN_DIR/plugin.conf"
LINEAR_BIN="${LINEAR_BIN:-linear}"

check_deps() {
    local ok=true
    if ! command -v "$LINEAR_BIN" > /dev/null 2>&1; then
        echo "  linear-sync: '$LINEAR_BIN' is required but not found" >&2
        echo "    Install: brew install schpet/tap/linear" >&2
        ok=false
    elif ! "$LINEAR_BIN" issue query --help >/dev/null 2>&1 || ! "$LINEAR_BIN" issue comment add --help >/dev/null 2>&1; then
        echo "  linear-sync: '$LINEAR_BIN' does not look like schpet/linear-cli" >&2
        echo "    Expected command shape: $LINEAR_BIN issue query --json ... / $LINEAR_BIN issue comment add ..." >&2
        ok=false
    fi
    if [[ -z "${LINEAR_PROJECT:-}" ]]; then
        echo "  linear-sync: LINEAR_PROJECT not configured" >&2
        echo "    Run: craft plugin set <project> linear-sync LINEAR_PROJECT <project-key>" >&2
        ok=false
    fi
    $ok
}

if [[ -z "$LINEAR_PROJECT" ]]; then
    return 0 2>/dev/null || exit 0
fi

# Check if a Linear issue already has a task file in the queue
_issue_has_task() {
    local issue_id="$1"
    local queue_dir="$PROJECT_DIR/queue"
    for dir in approved in-progress done blocked waiting pending; do
        if grep -rl "^linear_id: ${issue_id}$" "$queue_dir/$dir/" 2>/dev/null | head -1 | grep -q .; then
            return 0
        fi
    done
    return 1
}

# Get the next task ID based on existing files
_next_task_id() {
    local queue_dir="$PROJECT_DIR/queue"
    local max=0
    for f in "$queue_dir"/*/*.md; do
        [[ -f "$f" ]] || continue
        local num
        num=$(basename "$f" .md | sed 's/task-//' | sed 's/^0*//')
        if [[ "$num" =~ ^[0-9]+$ ]] && (( num > max )); then
            max=$num
        fi
    done
    printf "task-%03d" $((max + 1))
}

# Called by the orchestrator on each poll cycle
on_poll() {
    local queue_dir="$PROJECT_DIR/queue"

    # Build the list command
    local cmd=("$LINEAR_BIN" issue query --project "$LINEAR_PROJECT" --state "$LINEAR_READY_STATE" --json --no-pager)
    [[ -n "$LINEAR_ASSIGNEE" ]] && cmd+=(--assignee "$LINEAR_ASSIGNEE")
    if [[ -n "$LINEAR_TEAM" ]]; then
        cmd+=(--team "$LINEAR_TEAM")
    else
        cmd+=(--all-teams)
    fi
    [[ -n "$LINEAR_WORKSPACE" ]] && cmd+=(--workspace "$LINEAR_WORKSPACE")

    local issues
    issues=$("${cmd[@]}" 2>/dev/null) || return 0

    # Parse each issue from JSON array
    local count
    count=$(echo "$issues" | jq '.nodes | length' 2>/dev/null) || return 0

    for (( i=0; i<count; i++ )); do
        local issue
        issue=$(echo "$issues" | jq ".nodes[$i]")

        local issue_id title description labels priority
        issue_id=$(echo "$issue" | jq -r '.identifier')
        title=$(echo "$issue" | jq -r '.title')
        description=$(echo "$issue" | jq -r '.description // ""')
        priority=$(echo "$issue" | jq -r '.priority // 0')

        # Skip if we already have a task for this issue
        if _issue_has_task "$issue_id"; then
            continue
        fi

        # Check label filter if configured
        if [[ -n "$LINEAR_LABEL" ]]; then
            local has_label
            has_label=$(echo "$issue" | jq -r --arg label "$LINEAR_LABEL" \
                '.labels.nodes[]?.name // empty | select(. == $label)' 2>/dev/null)
            if [[ -z "$has_label" ]]; then
                continue
            fi
        fi

        # Generate a task file
        local task_id
        task_id=$(_next_task_id)

        # Read BRANCH_PREFIX from project config
        local branch_prefix=""
        local config_file="$PROJECT_DIR/craft.conf"
        if [[ -f "$config_file" ]]; then
            branch_prefix=$(grep '^BRANCH_PREFIX=' "$config_file" | sed 's/^BRANCH_PREFIX=//' | tr -d '"')
        fi

        # Build a branch name from the issue ID and title
        local branch_slug
        branch_slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | cut -c1-50)
        local branch="${branch_prefix}${issue_id}/${branch_slug}"

        local task_file="$queue_dir/approved/${task_id}.md"

        cat > "$task_file" << TASK_EOF
---
id: ${task_id}
type: pr
status: approved
linear_id: ${issue_id}
depends_on: []
repos: []
branch: ${branch}
qa:
  unit_tests: true
  integration_tests: false
---

## Summary

${title}

## Description

${description}

## Acceptance Criteria

See Linear issue ${issue_id} for full requirements.

## Work Log
TASK_EOF

        echo "[linear-sync] Created ${task_id} from ${issue_id}: ${title}"
    done
}

# Update Linear issue state helper
_update_linear_state() {
    local task_file="$1" new_state="$2"
    [[ -n "$new_state" ]] || return 0
    local linear_id
    linear_id=$(grep '^linear_id:' "$task_file" 2>/dev/null | sed 's/^linear_id:[[:space:]]*//')
    if [[ -n "$linear_id" ]]; then
        local cmd=("$LINEAR_BIN" issue update "$linear_id" --state "$new_state")
        [[ -n "$LINEAR_WORKSPACE" ]] && cmd+=(--workspace "$LINEAR_WORKSPACE")
        "${cmd[@]}" 2>/dev/null || true
    fi
}

# Find task file by ID across all queue directories
_find_task_file() {
    local task_id="$1"
    local queue_dir="$PROJECT_DIR/queue"
    for dir in approved in-progress done blocked waiting; do
        local f="$queue_dir/$dir/${task_id}.md"
        if [[ -f "$f" ]]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

# Called when a task starts (moved to in-progress)
on_started() {
    local task_id=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --task-id) task_id="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    local task_file
    task_file=$(_find_task_file "$task_id") || return 0
    _update_linear_state "$task_file" "$LINEAR_IN_PROGRESS_STATE"
}

# Called when a task moves to waiting (PR created)
on_waiting() {
    local task_id=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --task-id) task_id="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    local task_file
    task_file=$(_find_task_file "$task_id") || return 0
    _update_linear_state "$task_file" "$LINEAR_WAITING_STATE"
}

# Called when a task is done (PR merged)
on_done() {
    local task_id=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --task-id) task_id="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    local task_file
    task_file=$(_find_task_file "$task_id") || return 0
    _update_linear_state "$task_file" "$LINEAR_DONE_STATE"
}

# Called when a task is blocked
on_blocked() {
    local task_id="" reason=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --task-id) task_id="$2"; shift 2 ;;
            --reason) reason="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    local task_file
    task_file=$(_find_task_file "$task_id") || return 0
    _update_linear_state "$task_file" "$LINEAR_BLOCKED_STATE"

    # Also add a comment to the Linear issue with the reason
    if [[ -n "$reason" ]]; then
        local linear_id
        linear_id=$(grep '^linear_id:' "$task_file" 2>/dev/null | sed 's/^linear_id:[[:space:]]*//')
        if [[ -n "$linear_id" ]]; then
            "$LINEAR_BIN" issue comment add "$linear_id" --body "Blocked by craft: $reason" 2>/dev/null || true
        fi
    fi
}
