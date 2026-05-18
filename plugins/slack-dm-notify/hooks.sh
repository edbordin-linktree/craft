#!/usr/bin/env bash
# slack-dm-notify — Sends Slack DMs when tasks need attention
#
# Implements: on_waiting
# Sends a DM when a task creates a draft PR (or research task has findings).
#
# Required plugin.conf keys:
#   SLACK_BOT_TOKEN   xoxb-... bot token from your Slack app
#   SLACK_USER_ID     Your Slack member ID (e.g. UD6CDQZQE)

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "$PLUGIN_DIR/plugin.conf"

check_deps() {
    local ok=true
    if ! command -v curl > /dev/null 2>&1; then
        echo "  slack-dm-notify: 'curl' is required but not found" >&2
        ok=false
    fi
    if ! command -v jq > /dev/null 2>&1; then
        echo "  slack-dm-notify: 'jq' is required but not found" >&2
        ok=false
    fi
    if [[ -z "${SLACK_BOT_TOKEN:-}" ]]; then
        echo "  slack-dm-notify: SLACK_BOT_TOKEN not configured" >&2
        echo "    Run: craft plugin set <project> slack-dm-notify SLACK_BOT_TOKEN <token>" >&2
        ok=false
    fi
    if [[ -z "${SLACK_USER_ID:-}" ]]; then
        echo "  slack-dm-notify: SLACK_USER_ID not configured" >&2
        echo "    Run: craft plugin set <project> slack-dm-notify SLACK_USER_ID <id>" >&2
        ok=false
    fi
    $ok
}

_send_dm() {
    local text="$1"
    local attempt max_attempts=3
    for (( attempt=1; attempt<=max_attempts; attempt++ )); do
        local response
        response=$(curl -s -w "\n%{http_code}" -X POST https://slack.com/api/chat.postMessage \
            -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"channel\":\"$SLACK_USER_ID\",\"text\":$(printf '%s' "$text" | jq -Rs .)}")

        local http_code body
        http_code=$(echo "$response" | tail -1)
        body=$(echo "$response" | sed '$d')

        if [[ "$http_code" == "200" ]] && echo "$body" | jq -e '.ok' > /dev/null 2>&1; then
            return 0
        fi

        if (( attempt < max_attempts )); then
            sleep 1
        else
            echo "[slack-dm-notify] Failed after $max_attempts attempts (HTTP $http_code)" >&2
        fi
    done
}

# Find a task file by ID, searching likely queue states
_find_task_file() {
    local task_id="$1"
    local queue_dir
    queue_dir="$(cd "$PLUGIN_DIR/../.." && pwd)/queue"
    for dir in waiting in-progress done blocked; do
        local f
        for f in "$queue_dir/$dir"/*.md; do
            [[ -f "$f" ]] || continue
            if grep -q "^id: $task_id$" "$f"; then
                echo "$f"
                return 0
            fi
        done
    done
    return 1
}

# Extract the first # heading from a task file as its title
_task_title() {
    local file="$1"
    grep '^# ' "$file" | head -1 | sed 's/^# //'
}

on_waiting() {
    local task_id=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --task-id) task_id="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    [[ -z "$task_id" ]] && return 0

    local task_file
    task_file=$(_find_task_file "$task_id") || return 0

    local pr_url task_type task_title project_name
    pr_url=$(grep '^pr:' "$task_file" | sed 's/^pr:[[:space:]]*//')
    task_type=$(grep '^type:' "$task_file" | sed 's/^type:[[:space:]]*//')
    task_title=$(_task_title "$task_file")
    project_name=$(basename "$(cd "$PLUGIN_DIR/../.." && pwd)")

    local msg
    if [[ "$task_type" == "research" ]]; then
        msg="*[$project_name]* Research task *$task_id* has findings ready"
        [[ -n "$task_title" ]] && msg="${msg}"$'\n'"${task_title}"
        msg="${msg}"$'\n'"Check tmux: \`craft-$project_name\` → window \`$task_id\`"
    elif [[ -n "$pr_url" ]]; then
        msg="*[$project_name]* Draft PR ready for review - *$task_id*: ${pr_url}"
        [[ -n "$task_title" ]] && msg="${msg}"$'\n'"${task_title}"
    else
        msg="*[$project_name]* Task *$task_id* is waiting for your attention"
        [[ -n "$task_title" ]] && msg="${msg}"$'\n'"${task_title}"
    fi

    _send_dm "$msg"
}
