#!/usr/bin/env bash
# runtime.sh — Task runtime primitives: stages, task sessions, events, surfaces.

if [[ -z "${CRAFT_ROOT:-}" ]]; then
    _RUNTIME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CRAFT_ROOT="$(cd "$_RUNTIME_LIB_DIR/../.." && pwd)"
fi

# shellcheck source=bin/lib/queue.sh
source "$CRAFT_ROOT/bin/lib/queue.sh"

CRAFT_STAGE_ORDER=(context setup_worktree implement qa local_review pr_review complete blocked cleanup)

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

runtime_valid_stage() {
    local stage="$1" known
    [[ -n "$stage" ]] || return 1
    for known in "${CRAFT_STAGE_ORDER[@]}"; do
        [[ "$stage" == "$known" ]] && return 0
    done
    return 1
}

runtime_stage_next() {
    local current="$1" i
    for i in "${!CRAFT_STAGE_ORDER[@]}"; do
        if [[ "${CRAFT_STAGE_ORDER[$i]}" == "$current" ]]; then
            if (( i + 1 < ${#CRAFT_STAGE_ORDER[@]} )); then
                echo "${CRAFT_STAGE_ORDER[$((i + 1))]}"
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

runtime_hook() {
    local project_dir="$1" hook="$2"
    shift 2
    local hook_runner="${CRAFT_HOOK_RUNNER:-$CRAFT_ROOT/bin/run-hook.sh}"
    [[ -x "$hook_runner" ]] || return 0
    "$hook_runner" "$hook" --project-dir "$project_dir" "$@" 2>/dev/null || true
}

runtime_stage_set() {
    local project_dir="$1" task_id="$2" stage="$3" reason="$4" stage_status="${5:-active}"
    local task_file task_dir status
    runtime_valid_stage "$stage" || { echo "invalid_stage: $stage" >&2; return 2; }
    task_file="$(runtime_task_file "$project_dir" "$task_id")" || { echo "task_not_found: $task_id" >&2; return 1; }
    task_dir="$(runtime_task_dir "$project_dir" "$task_id")"
    status="$(runtime_task_status "$task_file")"

    runtime_hook "$project_dir" on_stage_before \
        --stage "$stage" --task-id "$task_id" --task-file "$task_file" \
        --task-dir "$task_dir" --status "$status" --reason "$reason"

    runtime_set_task_field "$task_file" stage "$stage"
    runtime_set_task_field "$task_file" stage_status "$stage_status"
    runtime_set_task_field "$task_file" stage_reason "$reason"

    runtime_hook "$project_dir" on_stage_after \
        --stage "$stage" --task-id "$task_id" --task-file "$task_file" \
        --task-dir "$task_dir" --status "$status" --reason "$reason"

    echo "$stage"
}

runtime_stage_advance() {
    local project_dir="$1" task_id="$2" reason="$3"
    local task_file current next
    task_file="$(runtime_task_file "$project_dir" "$task_id")" || { echo "task_not_found: $task_id" >&2; return 1; }
    current="$(runtime_task_stage "$task_file")"
    [[ -n "$current" ]] || current="${CRAFT_STAGE_ORDER[0]}"
    if [[ "$current" == "${CRAFT_STAGE_ORDER[0]}" && -z "$(runtime_task_stage "$task_file")" ]]; then
        next="$current"
    else
        next="$(runtime_stage_next "$current")" || {
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
    local project_dir="$1" task_id="$2" type="$3" summary="$4" payload_file="$5"
    local pending_dir before file now rel_queue counts pending_after msg
    [[ -f "$payload_file" ]] || { echo "payload_not_found: $payload_file" >&2; return 1; }
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
        --slurpfile payload "$payload_file" \
        '{task_id: $task_id, type: $type, summary: $summary, created_at: $created_at, payload: $payload[0]}' > "$file"

    pending_after="$(runtime_event_count_total "$pending_dir")"
    counts="$(runtime_event_counts_text "$pending_dir")"
    rel_queue=".orchestrator/events/pending"
    if [[ "$before" == "0" ]]; then
        msg="CRAFT_EVENTS task=$task_id pending=$pending_after counts=$counts queue=$rel_queue"
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
