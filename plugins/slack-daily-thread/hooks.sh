#!/usr/bin/env bash
# slack-daily-thread — Posts PR events to a daily Slack thread
#
# Requires plugin.conf to be configured with SLACK_CHANNEL and SLACK_BOT_PATH.

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load plugin config
# shellcheck source=/dev/null
source "$PLUGIN_DIR/plugin.conf"

check_deps() {
    local ok=true
    if [[ -z "${SLACK_CHANNEL:-}" ]]; then
        echo "  slack-daily-thread: SLACK_CHANNEL not configured" >&2
        echo "    Run: craft plugin set <project> slack-daily-thread SLACK_CHANNEL <id>" >&2
        ok=false
    fi
    if [[ -z "${SLACK_BOT_PATH:-}" ]]; then
        echo "  slack-daily-thread: SLACK_BOT_PATH not configured" >&2
        echo "    Run: craft plugin set <project> slack-daily-thread SLACK_BOT_PATH <path>" >&2
        ok=false
    elif [[ ! -x "${SLACK_BOT_PATH}/post.sh" ]]; then
        echo "  slack-daily-thread: ${SLACK_BOT_PATH}/post.sh not found or not executable" >&2
        ok=false
    fi
    $ok
}

# Extract repo name from a GitHub PR URL (e.g. "content-moderation" from ".../content-moderation/pull/123")
_repo_from_url() {
    echo "$1" | sed 's|.*/\([^/]*\)/pull/.*|\1|'
}

# Check if a repo is allowed (allow list then exclude list)
_repo_allowed() {
    local repo="$1"

    # Check allow list (empty = allow all)
    if [[ -n "${SLACK_DAILY_THREAD_REPOS:-}" ]]; then
        local found=false IFS=','
        for allowed in $SLACK_DAILY_THREAD_REPOS; do
            [[ "$(echo "$allowed" | xargs)" == "$repo" ]] && found=true
        done
        $found || return 1
    fi

    # Check exclude list
    if [[ -n "${SLACK_DAILY_THREAD_REPOS_EXCLUDE:-}" ]]; then
        local IFS=','
        for excluded in $SLACK_DAILY_THREAD_REPOS_EXCLUDE; do
            [[ "$(echo "$excluded" | xargs)" == "$repo" ]] && return 1
        done
    fi

    return 0
}

# Called when a PR is marked as ready (draft → ready)
on_ready() {
    local pr_url="" pr_number="" pr_title=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pr-url) pr_url="$2"; shift 2 ;;
            --pr-number) pr_number="$2"; shift 2 ;;
            --pr-title) pr_title="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    # Check repo allowlist
    local repo
    repo=$(_repo_from_url "$pr_url")
    if ! _repo_allowed "$repo"; then
        return 0
    fi

    # Get today's thread timestamp
    local thread_ts
    thread_ts=$("$SLACK_BOT_PATH/pr-thread-cache.sh" get 2>/dev/null) || return 0

    "$SLACK_BOT_PATH/post.sh" \
        --channel "$SLACK_CHANNEL" \
        --thread "$thread_ts" \
        --text "${pr_title} - <${pr_url}|#${pr_number}>"
}
