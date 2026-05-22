#!/usr/bin/env bash
# runtime.sh — Task runtime primitives: stages, task sessions, events, surfaces.

if [[ -z "${CRAFT_ROOT:-}" ]]; then
    _RUNTIME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CRAFT_ROOT="$(cd "$_RUNTIME_LIB_DIR/../.." && pwd)"
fi

# shellcheck source=bin/lib/queue.sh
source "$CRAFT_ROOT/bin/lib/queue.sh"
# shellcheck source=bin/lib/workflow.sh
source "$CRAFT_ROOT/bin/lib/workflow.sh"

CRAFT_FALLBACK_STAGE_ORDER=(implement qa pr_review complete)
CRAFT_TERMINAL_STAGES=(blocked)

runtime_project_dir() {
    local d="${1:-$PWD}"
    if [[ -n "${PROJECT_DIR:-}" && -f "$PROJECT_DIR/craft.conf" ]]; then
        echo "$PROJECT_DIR"
        return 0
    fi
    while [[ "$d" != "/" ]]; do
        if [[ -f "$d/craft.conf" ]]; then
            echo "$d"
            return 0
        fi
        d="$(dirname "$d")"
    done
    return 1
}

runtime_task_dir() {
    local project_dir="$1" task_id="$2"
    echo "$project_dir/tasks/$task_id"
}

runtime_task_file() {
    local project_dir="$1" task_id="$2"
    local queue_dir="$project_dir/queue"
    local f
    for f in "$queue_dir"/*/"$task_id.md"; do
        [[ -f "$f" ]] && { echo "$f"; return 0; }
    done
    return 1
}

runtime_task_status() {
    local task_file="$1"
    task_field "$task_file" "status"
}

runtime_task_stage() {
    local task_file="$1"
    task_field "$task_file" "stage"
}

runtime_stage_order_for_task() {
    local project_dir="$1" task_file="$2"
    workflow_resolve_stages "$project_dir" "$task_file" 2>/dev/null || printf '%s\n' "${CRAFT_FALLBACK_STAGE_ORDER[@]}"
}

runtime_valid_stage_for_task() {
    local project_dir="$1" task_file="$2" stage="$3" known
    [[ -n "$stage" ]] || return 1
    for known in "${CRAFT_TERMINAL_STAGES[@]}"; do
        [[ "$stage" == "$known" ]] && return 0
    done
    while IFS= read -r known; do
        [[ "$stage" == "$known" ]] && return 0
    done < <(runtime_stage_order_for_task "$project_dir" "$task_file")
    return 1
}

runtime_stage_next_for_task() {
    local project_dir="$1" task_file="$2" current="$3"
    local stages=() i
    mapfile -t stages < <(runtime_stage_order_for_task "$project_dir" "$task_file")
    for i in "${!stages[@]}"; do
        if [[ "${stages[$i]}" == "$current" ]]; then
            if (( i + 1 < ${#stages[@]} )); then
                echo "${stages[$((i + 1))]}"
                return 0
            fi
            return 1
        fi
    done
    return 1
}

runtime_set_task_field() {
    local file="$1" field="$2" value="$3"
    local tmp
    tmp="$(mktemp)"
    awk -v field="$field" -v value="$value" '
        BEGIN { in_fm = 0; seen = 0; closing = 0 }
        NR == 1 && $0 == "---" { in_fm = 1; print; next }
        in_fm && $0 == "---" {
            if (!seen) print field ": " value
            in_fm = 0
            print
            next
        }
        in_fm && $0 ~ ("^" field ":") {
            print field ": " value
            seen = 1
            next
        }
        { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

runtime_append_work_log() {
    local file="$1" title="$2" body="${3:-}"
    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    {
        echo
        printf '### %s — %s\n' "$title" "$timestamp"
        if [[ -n "$body" ]]; then
            echo
            printf '%s\n' "$body"
        fi
    } >> "$file"
}

runtime_hook() {
    local project_dir="$1" hook="$2"
    shift 2
    local hook_runner="${CRAFT_HOOK_RUNNER:-$CRAFT_ROOT/bin/run-hook.sh}"
    [[ -x "$hook_runner" ]] || return 0
    "$hook_runner" "$hook" --project-dir "$project_dir" "$@" 2>/dev/null || true
}

runtime_stage_set() {
    local project_dir="$1" task_id="$2" stage="$3" reason="$4" stage_status="${5:-active}"
    local task_file task_dir status workflow options_json previous payload queue_state synced_file
    task_file="$(runtime_task_file "$project_dir" "$task_id")" || { echo "task_not_found: $task_id" >&2; return 1; }
    runtime_valid_stage_for_task "$project_dir" "$task_file" "$stage" || { echo "invalid_stage: $stage" >&2; return 2; }
    task_dir="$(runtime_task_dir "$project_dir" "$task_id")"
    status="$(runtime_task_status "$task_file")"
    workflow="$(workflow_task_workflow "$task_file")"
    options_json="$(workflow_task_options_json "$task_file")"
    previous="$(runtime_task_stage "$task_file" || true)"

    if [[ -n "$previous" && "$previous" != "$stage" ]]; then
        runtime_hook "$project_dir" on_stage_end \
            --stage "$previous" --next-stage "$stage" --task-id "$task_id" --task-file "$task_file" \
            --task-dir "$task_dir" --status "$status" --reason "$reason" \
            --workflow "$workflow" --workflow-options-json "$options_json"
    fi

    runtime_set_task_field "$task_file" stage "$stage"
    runtime_set_task_field "$task_file" stage_status "$stage_status"
    runtime_set_task_field "$task_file" stage_reason "$reason"

    if [[ -z "${RUNTIME_SUPPRESS_STAGE_QUEUE_SYNC:-}" ]]; then
        queue_state="$(runtime_queue_state_for_stage "$project_dir" "$task_file" "$stage" 2>/dev/null || true)"
        if [[ -n "$queue_state" ]]; then
            synced_file="$(runtime_queue_state_set_without_stage "$project_dir" "$task_id" "$queue_state" "$reason")" || return $?
            task_file="$synced_file"
            status="$queue_state"
            task_dir="$(runtime_task_dir "$project_dir" "$task_id")"
        fi
    fi

    runtime_hook "$project_dir" on_stage_start \
        --stage "$stage" --previous-stage "$previous" --task-id "$task_id" --task-file "$task_file" \
        --task-dir "$task_dir" --status "$status" --reason "$reason" \
        --workflow "$workflow" --workflow-options-json "$options_json"

    payload="$(mktemp)"
    jq -n \
        --arg task_id "$task_id" \
        --arg previous "$previous" \
        --arg stage "$stage" \
        --arg stage_status "$stage_status" \
        --arg reason "$reason" \
        --arg workflow "$workflow" \
        '{task_id:$task_id, from:$previous, to:$stage, previous_stage:$previous, stage:$stage, stage_status:$stage_status, reason:$reason, workflow:$workflow}' > "$payload"
    runtime_event_enqueue "$project_dir" "$task_id" "stage.changed" "stage changed to $stage" "$payload" >/dev/null || true
    rm -f "$payload"

    echo "$stage"
}

runtime_default_stage_for_status() {
    local status="$1"
    case "$status" in
        waiting) echo "pr_review" ;;
        done) echo "complete" ;;
        blocked) echo "blocked" ;;
        in-progress) echo "implement" ;;
        *) echo "" ;;
    esac
}

runtime_timestamp_field_for_status() {
    local status="$1"
    case "$status" in
        in-progress) echo "started" ;;
        local-review) echo "local_review_started" ;;
        waiting) echo "waiting" ;;
        done) echo "done" ;;
        blocked) echo "blocked" ;;
        *) echo "" ;;
    esac
}

runtime_queue_state_for_stage() {
    local project_dir="$1" task_file="$2" stage="$3" stage_file
    if [[ "$stage" == "blocked" ]]; then
        echo "blocked"
        return 0
    fi
    stage_file="$(workflow_stage_provider_file "$project_dir" "$stage")" || return 0
    workflow_stage_file_frontmatter "$stage_file" queue_state
}

runtime_queue_state_set_without_stage() {
    local project_dir="$1" task_id="$2" status="$3" reason="$4"
    local task_file task_dir queue_dir target_dir target timestamp_field timestamp current_status current_value
    task_file="$(runtime_task_file "$project_dir" "$task_id")" || { echo "task_not_found: $task_id" >&2; return 1; }
    task_dir="$(runtime_task_dir "$project_dir" "$task_id")"
    queue_dir="$project_dir/queue"
    target_dir="$queue_dir/$status"
    [[ -d "$target_dir" ]] || { echo "queue_state_not_found: $status" >&2; return 2; }
    target="$target_dir/$(basename "$task_file")"
    current_status="$(runtime_task_status "$task_file")"

    if [[ "$current_status" == "$status" && "$task_file" == "$target" ]]; then
        echo "$task_file"
        return 0
    fi

    runtime_hook "$project_dir" on_task_state_before \
        --task-id "$task_id" --task-file "$task_file" --task-dir "$task_dir" \
        --status "$status" --reason "$reason"

    runtime_set_task_field "$task_file" status "$status"
    timestamp_field="$(runtime_timestamp_field_for_status "$status")"
    if [[ -n "$timestamp_field" ]]; then
        timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        current_value="$(task_field "$task_file" "$timestamp_field" || true)"
        if [[ "$status" != "in-progress" || -z "$current_value" ]]; then
            runtime_set_task_field "$task_file" "$timestamp_field" "$timestamp"
        fi
    fi
    if [[ "$status" == "blocked" ]]; then
        runtime_set_task_field "$task_file" one_shot false
    fi

    if [[ "$task_file" != "$target" ]]; then
        mv "$task_file" "$target"
        task_file="$target"
    fi

    runtime_hook "$project_dir" on_task_state_after \
        --task-id "$task_id" --task-file "$task_file" --task-dir "$task_dir" \
        --status "$status" --reason "$reason"

    echo "$task_file"
}

runtime_task_state_set() {
    local project_dir="$1" task_id="$2" status="$3" reason="$4" stage="${5:-}" log_title="${6:-}" log_body="${7:-}"
    shift 7 || true
    local task_file task_dir queue_dir target_dir target timestamp_field timestamp current_value set_pair key value stage_to_set stage_status
    task_file="$(runtime_task_file "$project_dir" "$task_id")" || { echo "task_not_found: $task_id" >&2; return 1; }
    task_dir="$(runtime_task_dir "$project_dir" "$task_id")"
    queue_dir="$project_dir/queue"
    target_dir="$queue_dir/$status"
    [[ -d "$target_dir" ]] || { echo "queue_state_not_found: $status" >&2; return 2; }

    runtime_hook "$project_dir" on_task_state_before \
        --task-id "$task_id" --task-file "$task_file" --task-dir "$task_dir" \
        --status "$status" --reason "$reason"

    runtime_set_task_field "$task_file" status "$status"
    timestamp_field="$(runtime_timestamp_field_for_status "$status")"
    if [[ -n "$timestamp_field" ]]; then
        timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        current_value="$(task_field "$task_file" "$timestamp_field" || true)"
        if [[ "$status" != "in-progress" || -z "$current_value" ]]; then
            runtime_set_task_field "$task_file" "$timestamp_field" "$timestamp"
        fi
    fi
    if [[ "$status" == "blocked" ]]; then
        runtime_set_task_field "$task_file" one_shot false
    fi

    for set_pair in "$@"; do
        key="${set_pair%%=*}"
        value="${set_pair#*=}"
        [[ -n "$key" && "$key" != "$set_pair" ]] || { echo "invalid_field_assignment: $set_pair" >&2; return 2; }
        runtime_set_task_field "$task_file" "$key" "$value"
    done

    stage_to_set="$stage"
    [[ -n "$stage_to_set" ]] || stage_to_set="$(runtime_default_stage_for_status "$status")"
    if [[ -n "$stage_to_set" ]]; then
        stage_status="active"
        [[ "$status" == "done" ]] && stage_status="complete"
        [[ "$status" == "blocked" ]] && stage_status="blocked"
        ( RUNTIME_SUPPRESS_STAGE_QUEUE_SYNC=1 runtime_stage_set "$project_dir" "$task_id" "$stage_to_set" "$reason" "$stage_status" >/dev/null )
    fi

    target="$target_dir/$(basename "$task_file")"
    if [[ "$task_file" != "$target" ]]; then
        mv "$task_file" "$target"
        task_file="$target"
    fi

    if [[ -n "$log_title" ]]; then
        runtime_append_work_log "$task_file" "$log_title" "$log_body"
    fi

    runtime_hook "$project_dir" on_task_state_after \
        --task-id "$task_id" --task-file "$task_file" --task-dir "$task_dir" \
        --status "$status" --reason "$reason"

    echo "$task_file"
}

runtime_stage_advance() {
    local project_dir="$1" task_id="$2" reason="$3"
    local task_file recorded current next first
    task_file="$(runtime_task_file "$project_dir" "$task_id")" || { echo "task_not_found: $task_id" >&2; return 1; }
    recorded="$(runtime_task_stage "$task_file" || true)"
    first="$(runtime_stage_order_for_task "$project_dir" "$task_file" | head -1)"
    current="${recorded:-$first}"
    if [[ "$current" == "$first" && -z "$recorded" ]]; then
        next="$current"
    else
        next="$(runtime_stage_next_for_task "$project_dir" "$task_file" "$current")" || {
            echo "no_next_stage: $current" >&2
            return 2
        }
    fi
    runtime_stage_set "$project_dir" "$task_id" "$next" "$reason" active
}

runtime_task_session_file() {
    local project_dir="$1" task_id="$2"
    echo "$(runtime_task_dir "$project_dir" "$task_id")/.orchestrator/task-session.json"
}

runtime_write_task_session() {
    local project_dir="$1" task_id="$2" workspace_id="$3" workspace_title="$4" session="$5" pane_name="$6"
    local task_dir file
    task_dir="$(runtime_task_dir "$project_dir" "$task_id")"
    file="$(runtime_task_session_file "$project_dir" "$task_id")"
    mkdir -p "$(dirname "$file")"
    jq -n \
        --arg task_id "$task_id" \
        --arg workspace_id "$workspace_id" \
        --arg workspace_title "$workspace_title" \
        --arg project_name "$(basename "$project_dir")" \
        --arg task_dir "$task_dir" \
        --arg session "$session" \
        --arg pane_name "$pane_name" \
        '{
          task_id: $task_id,
          workspace_id: $workspace_id,
          workspace_title: $workspace_title,
          project_name: $project_name,
          task_dir: $task_dir,
          session: $session,
          pane_name: $pane_name
        }' > "$file"
}

runtime_task_session_value() {
    local project_dir="$1" task_id="$2" key="$3"
    local file
    file="$(runtime_task_session_file "$project_dir" "$task_id")"
    [[ -f "$file" ]] || return 1
    jq -r --arg key "$key" '.[$key] // empty' "$file"
}

runtime_event_pending_dir() {
    local project_dir="$1" task_id="$2"
    echo "$(runtime_task_dir "$project_dir" "$task_id")/.orchestrator/events/pending"
}

runtime_event_count_total() {
    local pending_dir="$1"
    find "$pending_dir" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

runtime_event_counts_text() {
    local pending_dir="$1"
    if [[ ! -d "$pending_dir" ]] || [[ "$(runtime_event_count_total "$pending_dir")" == "0" ]]; then
        echo ""
        return 0
    fi
    jq -r '.type // "unknown"' "$pending_dir"/*.json 2>/dev/null \
        | sort \
        | uniq -c \
        | awk '{printf "%s%s:%s", sep, $2, $1; sep=","}'
}

runtime_event_enqueue() {
    local project_dir="$1" task_id="$2" type="$3" summary="$4" payload_file="$5" publisher="${6:-core}"
    local pending_dir before file now counts pending_after msg consume_file
    [[ -f "$payload_file" ]] || { echo "payload_not_found: $payload_file" >&2; return 1; }
    consume_file="$(mktemp)"
    export EVENT_CONSUME_FILE="$consume_file"
    runtime_hook "$project_dir" on_event \
        --task-id "$task_id" --event-type "$type" --event-summary "$summary" \
        --event-payload "$payload_file" --publisher "$publisher"
    unset EVENT_CONSUME_FILE
    if [[ -s "$consume_file" ]]; then
        rm -f "$consume_file"
        echo "event_consumed"
        return 0
    fi
    rm -f "$consume_file"

    pending_dir="$(runtime_event_pending_dir "$project_dir" "$task_id")"
    mkdir -p "$pending_dir"
    before="$(runtime_event_count_total "$pending_dir")"
    now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    file="$pending_dir/$(date -u '+%Y%m%dT%H%M%S')-$$-$RANDOM.json"
    jq -n \
        --arg task_id "$task_id" \
        --arg type "$type" \
        --arg summary "$summary" \
        --arg created_at "$now" \
        --arg publisher "$publisher" \
        --slurpfile payload "$payload_file" \
        '{task_id: $task_id, type: $type, summary: $summary, created_at: $created_at, publisher: $publisher, payload: $payload[0]}' > "$file"

    pending_after="$(runtime_event_count_total "$pending_dir")"
    counts="$(runtime_event_counts_text "$pending_dir")"
    if [[ "$before" == "0" ]]; then
        msg="CRAFT_EVENTS task=$task_id pending=$pending_after counts=$counts"
        if command -v craft-mux >/dev/null 2>&1; then
            craft-mux send-task "$task_id" "$msg" >/dev/null 2>&1 || true
        elif [[ -x "$CRAFT_ROOT/bin/craft-mux" ]]; then
            "$CRAFT_ROOT/bin/craft-mux" send-task "$task_id" "$msg" >/dev/null 2>&1 || true
        fi
    fi
    echo "$file"
}

runtime_event_counts() {
    local project_dir="$1" task_id="$2"
    local pending_dir total counts
    pending_dir="$(runtime_event_pending_dir "$project_dir" "$task_id")"
    mkdir -p "$pending_dir"
    total="$(runtime_event_count_total "$pending_dir")"
    counts="$(runtime_event_counts_text "$pending_dir")"
    printf 'pending=%s counts=%s\n' "$total" "$counts"
}

runtime_event_take() {
    local project_dir="$1" task_id="$2" type_filter="${3:-}" limit="${4:-}"
    local pending_dir files=() f selected=()
    pending_dir="$(runtime_event_pending_dir "$project_dir" "$task_id")"
    mkdir -p "$pending_dir"
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        if [[ -n "$type_filter" ]]; then
            [[ "$(jq -r '.type // empty' "$f")" == "$type_filter" ]] || continue
        fi
        selected+=("$f")
        if [[ -n "$limit" && "${#selected[@]}" -ge "$limit" ]]; then
            break
        fi
    done < <(find "$pending_dir" -maxdepth 1 -name '*.json' | sort)

    if [[ "${#selected[@]}" -eq 0 ]]; then
        echo "[]"
        return 0
    fi
    jq -s '.' "${selected[@]}"
    rm -f "${selected[@]}"
}

runtime_surface_registry() {
    local project_dir="$1" task_id="$2"
    echo "$(runtime_task_dir "$project_dir" "$task_id")/.orchestrator/surfaces.json"
}

runtime_surface_get() {
    local project_dir="$1" task_id="$2" surface_id="$3"
    local registry
    registry="$(runtime_surface_registry "$project_dir" "$task_id")"
    [[ -f "$registry" ]] || return 1
    jq -e --arg id "$surface_id" '.[$id]' "$registry"
}

runtime_surface_put() {
    local project_dir="$1" task_id="$2" surface_json="$3"
    local registry tmp surface_id
    registry="$(runtime_surface_registry "$project_dir" "$task_id")"
    mkdir -p "$(dirname "$registry")"
    [[ -f "$registry" ]] || echo '{}' > "$registry"
    surface_id="$(jq -r '.surface_id' <<< "$surface_json")"
    tmp="$(mktemp)"
    jq --arg id "$surface_id" --argjson surface "$surface_json" '.[$id] = $surface' "$registry" > "$tmp"
    mv "$tmp" "$registry"
}

runtime_surface_patch_ref() {
    local project_dir="$1" task_id="$2" surface_id="$3" surface_ref="$4" status="${5:-open}"
    local current
    current="$(runtime_surface_get "$project_dir" "$task_id" "$surface_id")" || return 1
    current="$(jq --arg ref "$surface_ref" --arg status "$status" '.cached_surface_ref = $ref | .status = $status' <<< "$current")"
    runtime_surface_put "$project_dir" "$task_id" "$current"
}
