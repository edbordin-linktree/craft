#!/usr/bin/env bash
# run-hook.sh — Dispatch a lifecycle hook to the plugins enabled in a project.
#
# Usage:
#   bin/run-hook.sh <hook-name> [--project-dir PATH] [args...]
#
# Hook names include task lifecycle hooks (on_started, on_waiting, on_done),
# stage hooks (on_stage_start, on_stage_end, on_stage_resume), polling hooks,
# event hooks, and plugin install hooks. Plugins may ignore hooks they do not
# implement.
#
# Plugins live at $CRAFT_ROOT/plugins/<plugin>/hooks.sh — shared across all
# projects in this craft installation. The project's craft.conf controls which
# plugins are active via PLUGINS=...

set -uo pipefail

if [[ ${BASH_VERSINFO[0]:-0} -lt 4 ]]; then
    echo "run-hook.sh requires bash 4+ (you have ${BASH_VERSION:-unknown})." >&2
    exit 1
fi

HOOK_NAME="${1:?Usage: run-hook.sh <hook-name> [--project-dir PATH] [args...]}"
shift

# Pull out --project-dir from anywhere in the arg list.
PROJECT_DIR_ARG=""
FILTERED_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-dir)
            PROJECT_DIR_ARG="$2"
            FILTERED_ARGS+=("$1" "$2")
            shift 2
            ;;
        *)
            FILTERED_ARGS+=("$1")
            shift
            ;;
    esac
done

PROJECT_DIR="${PROJECT_DIR_ARG:-${PROJECT_DIR:-}}"
if [[ -z "$PROJECT_DIR" ]]; then
    echo "run-hook.sh: PROJECT_DIR required (pass --project-dir or set env)" >&2
    exit 1
fi

# Resolve craft root + plugins library from this script's own location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # $CRAFT_ROOT/bin
CRAFT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGINS_LIB="$CRAFT_ROOT/plugins"
# shellcheck source=bin/lib/plugins.sh
source "$CRAFT_ROOT/bin/lib/plugins.sh"

EVENT_TASK_ID=""
EVENT_TYPE=""
EVENT_SUMMARY=""
EVENT_PAYLOAD=""
EVENT_PUBLISHER=""
if [[ "$HOOK_NAME" == "on_event" ]]; then
    _event_args=("${FILTERED_ARGS[@]}")
    while [[ ${#_event_args[@]} -gt 0 ]]; do
        case "${_event_args[0]}" in
            --task-id) EVENT_TASK_ID="${_event_args[1]:-}"; _event_args=("${_event_args[@]:2}") ;;
            --event-type) EVENT_TYPE="${_event_args[1]:-}"; _event_args=("${_event_args[@]:2}") ;;
            --event-summary) EVENT_SUMMARY="${_event_args[1]:-}"; _event_args=("${_event_args[@]:2}") ;;
            --event-payload) EVENT_PAYLOAD="${_event_args[1]:-}"; _event_args=("${_event_args[@]:2}") ;;
            --publisher) EVENT_PUBLISHER="${_event_args[1]:-}"; _event_args=("${_event_args[@]:2}") ;;
            *) _event_args=("${_event_args[@]:1}") ;;
        esac
    done
    export EVENT_TASK_ID EVENT_TYPE EVENT_SUMMARY EVENT_PAYLOAD EVENT_PUBLISHER EVENT_CONSUME_FILE
fi

event_consume() {
    [[ -n "${EVENT_CONSUME_FILE:-}" ]] && printf 'consumed\n' > "$EVENT_CONSUME_FILE"
}

event_publish() {
    local type="${1:?event type required}" payload="${2:?payload json required}" publisher="" summary=""
    shift 2 || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --publisher) publisher="${2:-}"; shift 2 ;;
            --summary) summary="${2:-}"; shift 2 ;;
            *) echo "event_publish: unknown arg: $1" >&2; return 2 ;;
        esac
    done
    [[ -n "${EVENT_TASK_ID:-}" ]] || { echo "event_publish: EVENT_TASK_ID unavailable" >&2; return 2; }
    [[ -n "$summary" ]] || summary="$type"
    [[ -n "$publisher" ]] || publisher="${EVENT_PUBLISHER:-plugin}"
    (
        cd "$PROJECT_DIR" || exit 1
        "$CRAFT_ROOT/bin/craft" event enqueue "$EVENT_TASK_ID" \
            --type "$type" --summary "$summary" --json "$payload" --publisher "$publisher"
    )
}

# Read PLUGINS from the project's conf.
PLUGINS=""
CONFIG_FILE="$PROJECT_DIR/craft.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

[[ -n "$PLUGINS" ]] || exit 0

IFS=',' read -ra PLUGIN_LIST <<< "$PLUGINS"
for plugin in "${PLUGIN_LIST[@]}"; do
    plugin="$(echo "$plugin" | xargs)"   # trim whitespace
    [[ -n "$plugin" ]] || continue
    hooks_file="$PLUGINS_LIB/$plugin/hooks.sh"

    if [[ ! -f "$hooks_file" ]]; then
        continue
    fi

    missing_deps="$(plugin_missing_dependencies "$PROJECT_DIR" "$plugin" | paste -sd, -)"
    if [[ -n "$missing_deps" ]]; then
        echo "[plugins] $plugin: missing DEPENDS_ON plugin(s): $missing_deps — skipping $HOOK_NAME" >&2
        continue
    fi

    # Run each plugin's hook in a subshell so plugins can't interfere.
    (
        export PROJECT_DIR
        # shellcheck source=/dev/null
        source "$hooks_file"

        if declare -f check_deps >/dev/null 2>&1; then
            if ! check_deps 2>&1; then
                echo "[plugins] $plugin: dependency check failed — skipping $HOOK_NAME" >&2
                exit 0
            fi
        fi

        if declare -f "$HOOK_NAME" >/dev/null 2>&1; then
            "$HOOK_NAME" ${FILTERED_ARGS[@]+"${FILTERED_ARGS[@]}"}
        fi
    )
done
