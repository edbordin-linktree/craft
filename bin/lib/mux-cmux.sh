#!/usr/bin/env bash
# mux-cmux.sh — cmux multiplexer provider for the craft orchestrator
#
# Uses cmux workspaces and surfaces instead of tmux sessions and windows.
# Identity lives in hidden cmux metadata so the same helpers work for attached
# Swift UI workspaces and detached remote snapshots.

# Requires bash 4+ (associative arrays in primitives, lowercase parameter expansion).
if [[ ${BASH_VERSINFO[0]:-0} -lt 4 ]]; then
    echo "mux-cmux.sh requires bash 4+ (you have ${BASH_VERSION:-unknown}). On macOS: 'brew install bash' then ensure /opt/homebrew/bin (or /usr/local/bin) is earlier on PATH than /bin." >&2
    return 1 2>/dev/null || exit 1
fi

# Workspace name prefix
CMUX_PREFIX="craft"
CMUX_CRAFT_SCHEMA_VERSION="1"

_cmux_craft_root() {
    if [[ -n "${CRAFT_ROOT:-}" ]]; then
        echo "$CRAFT_ROOT"
        return
    fi
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P
}

_cmux_surface_key() {
    echo "craft:surface:$1"
}

_cmux_now_utc() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

_cmux_workspace_ref_from_json() {
    jq -r '
        [
          .matches[]?,
          .workspaces[]?,
          .
        ]
        | map(select(type == "object"))
        | .[]
        | .workspace_id // .workspaceId // .id // .workspace_ref // .workspaceRef // .ref // empty
    ' 2>/dev/null | head -1
}

_cmux_workspace_id_from_output() {
    jq -r '.local_workspace_id // .localWorkspaceId // .workspace_id // .workspaceId // .id // .workspace_ref // .workspaceRef // .ref // empty' 2>/dev/null | head -1
}

_cmux_workspace_lookup_by_metadata() {
    local args=("--include-detached" "--json")
    local pair
    for pair in "$@"; do
        [[ -n "$pair" ]] || continue
        args+=("--metadata" "$pair")
    done
    cmux workspace lookup "${args[@]}" 2>/dev/null | _cmux_workspace_ref_from_json
}

_cmux_workspace_lookup_json_by_metadata() {
    local args=("--include-detached" "--json")
    local pair
    for pair in "$@"; do
        [[ -n "$pair" ]] || continue
        args+=("--metadata" "$pair")
    done
    cmux workspace lookup "${args[@]}" 2>/dev/null
}

_cmux_workspace_lookup_item_from_json() {
    jq -c '
        [
          .matches[]?,
          .workspaces[]?,
          .workspace?,
          .
        ]
        | map(select(type == "object"))
        | map(select((.workspace_id // .workspaceId // .id // .workspace_ref // .workspaceRef // .ref // "") != ""))
        | .[0] // empty
    ' 2>/dev/null
}

_cmux_running_in_remote_workspace() {
    [[ -n "${CMUX_WORKSPACE_ID:-}" && -n "${CMUX_REMOTE_DAEMON_SLOT:-}" ]]
}

_cmux_same_host_destination() {
    local user host
    user="${USER:-}"
    [[ -n "$user" ]] || user="$(id -un 2>/dev/null || true)"
    host="$(hostname 2>/dev/null || true)"
    [[ -n "$host" ]] || host="localhost"
    if [[ -n "$user" ]]; then
        echo "${user}@${host}"
    else
        echo "$host"
    fi
}

_cmux_metadata_get() {
    local ws_ref="$1" key="$2"
    local raw
    raw="$(cmux metadata get --workspace "$ws_ref" "$key" --json 2>/dev/null)" || return 1
    jq -r '
        def value:
          if type == "object" and has("value") then .value
          elif type == "object" and has("entry") then .entry.value
          else .
          end;
        value
        | if . == null then empty
          elif type == "string" then .
          else @json
          end
    ' <<< "$raw" 2>/dev/null
}

_cmux_metadata_set() {
    local ws_ref="$1" key="$2" value="$3"
    cmux metadata set --workspace "$ws_ref" "$key" "$value" >/dev/null 2>&1
}

_cmux_metadata_set_json() {
    local ws_ref="$1" key="$2" json="$3"
    cmux metadata set --workspace "$ws_ref" "$key" --value-json "$json" >/dev/null 2>&1
}

_cmux_metadata_clear() {
    local ws_ref="$1" key="$2"
    cmux metadata clear --workspace "$ws_ref" "$key" >/dev/null 2>&1 || true
}

_cmux_clear_workspace_identity() {
    local ws_ref="$1"
    _cmux_metadata_clear "$ws_ref" "craft:schema-version"
    _cmux_metadata_clear "$ws_ref" "craft:project-id"
    _cmux_metadata_clear "$ws_ref" "craft:project-dir"
    _cmux_metadata_clear "$ws_ref" "craft:task-id"
    _cmux_metadata_clear "$ws_ref" "craft:task-dir"
}

_cmux_close_workspace_async() {
    local ws_ref="$1"
    [[ -n "$ws_ref" ]] || return 0
    if [[ "${CMUX_CLOSE_WORKSPACE_SYNC:-}" == "1" ]]; then
        cmux close-workspace --workspace "$ws_ref" >/dev/null 2>&1 || true
        return 0
    fi
    nohup bash -c '
        sleep "${CMUX_CLOSE_WORKSPACE_DELAY:-1}"
        cmux close-workspace --workspace "$1" >/dev/null 2>&1 || true
    ' _ "$ws_ref" </dev/null >/dev/null 2>&1 &
}

_cmux_tree_json() {
    local ws_ref="$1"
    cmux tree --workspace "$ws_ref" --json 2>/dev/null
}

_cmux_project_workspace_ref() {
    local project_id="$1" candidate task_id
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        task_id="$(_cmux_metadata_get "$candidate" "craft:task-id" 2>/dev/null || true)"
        if [[ -z "$task_id" ]]; then
            echo "$candidate"
            return 0
        fi
    done < <(
        cmux workspace lookup \
            --metadata "craft:project-id=${project_id}" \
            --include-detached \
            --json 2>/dev/null \
            | jq -r '
                [
                  .matches[]?,
                  .workspaces[]?,
                  .
                ]
                | map(select(type == "object"))
                | .[]
                | .workspace_id // .workspaceId // .id // .workspace_ref // .workspaceRef // .ref // empty
            ' 2>/dev/null
    )
    return 1
}

_cmux_task_workspace_ref() {
    local project_id="$1" task_id="$2"
    _cmux_workspace_lookup_by_metadata \
        "craft:project-id=${project_id}" \
        "craft:task-id=${task_id}"
}

_cmux_session_project_id() {
    local session="$1" prefix="${CMUX_PREFIX:-craft}-"
    if [[ -n "${PROJECT_NAME:-}" ]]; then
        echo "$PROJECT_NAME"
        return
    fi
    session="${session#"$prefix"}"
    echo "${session%%-*}"
}

_cmux_session_task_id() {
    local session="$1" project_id="${2:-${PROJECT_NAME:-}}" prefix
    [[ -n "$project_id" ]] || return 1
    prefix="${CMUX_PREFIX:-craft}-${project_id}-"
    [[ "$session" == "$prefix"* ]] || return 1
    echo "${session#"$prefix"}"
}

_cmux_write_workspace_identity() {
    local ws_ref="$1" project_id="$2" project_dir="$3" task_id="${4:-}" task_dir="${5:-}"
    _cmux_metadata_set "$ws_ref" "craft:schema-version" "$CMUX_CRAFT_SCHEMA_VERSION" || return 1
    _cmux_metadata_set "$ws_ref" "craft:project-id" "$project_id" || return 1
    if [[ -n "$project_dir" ]]; then
        _cmux_metadata_set "$ws_ref" "craft:project-dir" "$project_dir" || return 1
    fi
    if [[ -n "$task_id" ]]; then
        _cmux_metadata_set "$ws_ref" "craft:task-id" "$task_id" || return 1
        if [[ -n "$task_dir" ]]; then
            _cmux_metadata_set "$ws_ref" "craft:task-dir" "$task_dir" || return 1
        fi
    fi
}

_cmux_surface_exists() {
    local ws_ref="$1" surface_id="$2"
    [[ -n "$surface_id" ]] || return 1
    _cmux_tree_json "$ws_ref" \
        | jq -e --arg ref "$surface_id" '
            ($ref | ascii_downcase) as $want
            |
            .windows[].workspaces[].panes[].surfaces[]
            | ((.ref // .id // .surface_id // .surfaceId // "") | ascii_downcase) as $actual
            | select($actual == $want)
        ' >/dev/null 2>&1
}

_cmux_surface_metadata_set() {
    local ws_ref="$1" surface_id="$2" key="$3" value="$4"
    [[ -n "$value" ]] || return 0
    cmux surface metadata set --workspace "$ws_ref" --surface "$surface_id" "$key" "$value" >/dev/null 2>&1
}

_cmux_surface_metadata_clear() {
    local ws_ref="$1" surface_id="$2" key="$3"
    cmux surface metadata clear --workspace "$ws_ref" --surface "$surface_id" "$key" >/dev/null 2>&1 || true
}

_cmux_surface_lookup_by_metadata() {
    local ws_ref="$1"
    shift
    local args=(surface lookup --workspace "$ws_ref" --json) pair
    for pair in "$@"; do
        [[ -n "$pair" ]] || continue
        args+=(--metadata "$pair")
    done
    cmux "${args[@]}" 2>/dev/null
}

_cmux_surface_normalize_lookup_json() {
    local semantic="${1:-}"
    jq -c --arg semantic "$semantic" '
        [
          .matches[]?,
          .surfaces[]?,
          .surface?,
          .match?,
          .
        ]
        | map(select(type == "object"))
        | .[0] as $s
        | select($s != null)
        | ($s.metadata // {}) as $m
        | ($s.surface_ref // $s.surfaceRef // $s.ref // $s.surface_id // $s.surfaceId // $s.id // empty) as $ref
        | select($ref != "")
        | {
            surface_id: $ref,
            surface_ref: $ref,
            id: ($s.id // $s.surface_id // $s.surfaceId // $ref),
            type: ($s.type // $m["craft:type"] // $m["craft:kind"] // ""),
            purpose: ($m["craft:purpose"] // $semantic),
            title: ($s.title // $m["craft:title"] // ""),
            url: ($s.url // $m["craft:url"] // ""),
            agent: ($m["craft:agent"] // ""),
            placement: ($m["craft:placement"] // ""),
            owner: ($m["craft:owner"] // ""),
            stage: ($m["craft:stage"] // ""),
            url_match: ($m["craft:url_match"] // "")
          }
    ' 2>/dev/null
}

_cmux_surface_from_surface_metadata() {
    local ws_ref="$1" semantic="$2" raw surface_id
    raw="$(_cmux_surface_lookup_by_metadata "$ws_ref" "craft:semantic=${semantic}")" || return 1
    [[ -n "$raw" ]] || return 1
    raw="$(printf '%s' "$raw" | _cmux_surface_normalize_lookup_json "$semantic")" || return 1
    [[ -n "$raw" ]] || return 1
    surface_id="$(jq -r '.surface_id // empty' <<< "$raw" 2>/dev/null)"
    [[ -n "$surface_id" ]] || return 1
    _cmux_surface_exists "$ws_ref" "$surface_id" || return 1
    echo "$raw"
}

_cmux_legacy_surface_from_workspace_metadata() {
    local ws_ref="$1" semantic="$2" key value surface_id type purpose title url agent placement
    key="$(_cmux_surface_key "$semantic")"
    value="$(_cmux_metadata_get "$ws_ref" "$key" 2>/dev/null || true)"
    [[ -n "$value" ]] || return 1
    surface_id="$(jq -r '.surface_id // .surface_ref // .ref // empty' <<< "$value" 2>/dev/null)"
    [[ -n "$surface_id" ]] || return 1
    _cmux_surface_exists "$ws_ref" "$surface_id" || return 1
    type="$(jq -r '.type // .kind // empty' <<< "$value" 2>/dev/null)"
    purpose="$(jq -r '.purpose // empty' <<< "$value" 2>/dev/null)"
    title="$(jq -r '.title // empty' <<< "$value" 2>/dev/null)"
    url="$(jq -r '.url // empty' <<< "$value" 2>/dev/null)"
    agent="$(jq -r '.agent // empty' <<< "$value" 2>/dev/null)"
    placement="$(jq -r '.placement // empty' <<< "$value" 2>/dev/null)"
    _cmux_record_surface "$ws_ref" "$semantic" "$surface_id" "$type" "${purpose:-$semantic}" "$title" "$url" "$agent" "$placement" || true
    _cmux_metadata_clear "$ws_ref" "$key"
    _cmux_surface_from_surface_metadata "$ws_ref" "$semantic"
}

_cmux_surface_from_metadata() {
    local ws_ref="$1" semantic="$2"
    _cmux_surface_from_surface_metadata "$ws_ref" "$semantic" \
        || _cmux_legacy_surface_from_workspace_metadata "$ws_ref" "$semantic"
}

_cmux_record_surface() {
    local ws_ref="$1" semantic="$2" surface_id="$3" type="$4" purpose="$5" title="${6:-}" url="${7:-}" agent="${8:-}" placement="${9:-}"
    [[ -n "$placement" ]] || placement="$(_cmux_default_placement "$semantic")"
    [[ -n "$surface_id" ]] || return 1
    _cmux_surface_metadata_set "$ws_ref" "$surface_id" "craft:schema-version" "$CMUX_CRAFT_SCHEMA_VERSION" || return 1
    _cmux_surface_metadata_set "$ws_ref" "$surface_id" "craft:semantic" "$semantic" || return 1
    _cmux_surface_metadata_set "$ws_ref" "$surface_id" "craft:type" "$type" || return 1
    _cmux_surface_metadata_set "$ws_ref" "$surface_id" "craft:purpose" "$purpose" || return 1
    _cmux_surface_metadata_set "$ws_ref" "$surface_id" "craft:title" "$title" || true
    _cmux_surface_metadata_set "$ws_ref" "$surface_id" "craft:url" "$url" || true
    _cmux_surface_metadata_set "$ws_ref" "$surface_id" "craft:agent" "$agent" || true
    _cmux_surface_metadata_set "$ws_ref" "$surface_id" "craft:placement" "$placement" || true
    _cmux_surface_metadata_set "$ws_ref" "$surface_id" "craft:updated_at" "$(_cmux_now_utc)" || true
    _cmux_metadata_clear "$ws_ref" "$(_cmux_surface_key "$semantic")"
}

_cmux_surface_id_from_output() {
    jq -r '.surface_ref // .surfaceRef // .ref // .surface_id // .surfaceId // empty' 2>/dev/null | head -1
}

_cmux_send_command_to_surface() {
    local ws_ref="$1" surface_id="$2" command="$3"
    [[ -n "$command" ]] || return 0
    cmux send --workspace "$ws_ref" --surface "$surface_id" "$command" >/dev/null 2>&1 || return 1
    cmux send-key --workspace "$ws_ref" --surface "$surface_id" enter >/dev/null 2>&1 || return 1
}

_cmux_focus_surface_ui() {
    local ws_ref="$1" surface_id="$2"
    local out
    [[ -n "$ws_ref" && -n "$surface_id" ]] || return 1

    out="$(cmux focus-surface --workspace "$ws_ref" --surface "$surface_id" 2>&1)" || {
        local focus_error="$out"
        out="$(cmux select-workspace --workspace "$ws_ref" 2>&1)" || {
            echo "cmux_ui_unavailable: focus-surface failed for $surface_id in $ws_ref: $focus_error; select-workspace fallback failed: $out" >&2
            return 1
        }
        out="$(cmux focus-surface --workspace "$ws_ref" --surface "$surface_id" 2>&1)" || {
            echo "cmux_ui_unavailable: focus-surface failed for $surface_id in $ws_ref: $out" >&2
            return 1
        }
    }
}

_cmux_workspace_uuid() {
    local ws_ref="$1"
    if [[ "$ws_ref" =~ ^workspace:([0-9A-Fa-f-]{36})$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$ws_ref" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
        echo "$ws_ref"
    fi
}

_cmux_attach_workspace_ui() {
    local ws_ref="$1"
    local workspace_uuid raw attached_ref
    workspace_uuid="$(_cmux_workspace_uuid "$ws_ref")"
    [[ -n "$workspace_uuid" ]] || {
        echo "cmux_ui_unavailable: cannot attach non-UUID workspace ref $ws_ref" >&2
        return 1
    }
    raw="$(cmux ssh-workspace-attach --workspace-id "$workspace_uuid" --json 2>&1)" || {
        echo "cmux_ui_unavailable: ssh-workspace-attach failed for $workspace_uuid: $raw" >&2
        return 1
    }
    attached_ref="$(printf '%s' "$raw" | _cmux_workspace_id_from_output)"
    echo "${attached_ref:-$ws_ref}"
}

_cmux_pane_id_from_output() {
    jq -r '.pane_ref // .paneRef // .pane_id // .paneId // empty' 2>/dev/null | head -1
}

_cmux_default_placement() {
    local semantic="$1"
    if [[ "$semantic" == "agent" || "$semantic" == "orchestrator" || "$semantic" == "dashboard" ]]; then
        echo "left"
    else
        echo "right"
    fi
}

_cmux_agent_surface_id() {
    local ws_ref="$1" surface_json
    surface_json="$(_cmux_surface_from_metadata "$ws_ref" "agent" 2>/dev/null || true)"
    [[ -n "$surface_json" ]] || return 1
    jq -r '.surface_id // empty' <<< "$surface_json"
}

_cmux_left_anchor_surface_id() {
    local ws_ref="$1" surface_json
    surface_json="$(_cmux_surface_from_metadata "$ws_ref" "agent" 2>/dev/null || true)"
    if [[ -n "$surface_json" ]]; then
        jq -r '.surface_id // empty' <<< "$surface_json"
        return 0
    fi
    surface_json="$(_cmux_surface_from_metadata "$ws_ref" "orchestrator" 2>/dev/null || true)"
    [[ -n "$surface_json" ]] || return 1
    jq -r '.surface_id // empty' <<< "$surface_json"
}

_cmux_first_pane() {
    local ws_ref="$1"
    _cmux_tree_json "$ws_ref" \
        | jq -r '.windows[].workspaces[].panes[].ref' 2>/dev/null \
        | head -1
}

_cmux_pane_for_placement() {
    local ws_ref="$1" placement="$2"
    local left_anchor_surface
    left_anchor_surface="$(_cmux_left_anchor_surface_id "$ws_ref" 2>/dev/null || true)"

    if [[ "$placement" == "left" ]]; then
        if [[ -n "$left_anchor_surface" ]]; then
            _cmux_pane_for_surface "$ws_ref" "$left_anchor_surface"
            return
        fi
        _cmux_first_pane "$ws_ref"
        return
    fi

    local pane
    pane="$(_cmux_tree_json "$ws_ref" \
        | jq -r --arg left_anchor "$left_anchor_surface" '
            .windows[].workspaces[].panes[]
            | select(if $left_anchor == "" then true else all(.surfaces[]?; .ref != $left_anchor) end)
            | select(.surfaces[]? | .type == "browser")
            | .ref
          ' 2>/dev/null \
        | head -1)"
    if [[ -n "$pane" ]]; then
        echo "$pane"
        return
    fi

    _cmux_any_non_agent_pane "$ws_ref"
}

_cmux_first_terminal_surface_in_pane() {
    local ws_ref="$1" pane="$2"
    _cmux_tree_json "$ws_ref" \
        | jq -r --arg pane "$pane" '
            .windows[].workspaces[].panes[]
            | select((.ref // .id // .pane_id // .paneId) == $pane)
            | .surfaces[]?
            | select(.type == "terminal")
            | .ref // .id // .surface_id // .surfaceId // empty
          ' 2>/dev/null \
        | head -1
}

_cmux_any_non_agent_pane() {
    local ws_ref="$1"
    local agent_surface
    agent_surface="$(_cmux_agent_surface_id "$ws_ref" 2>/dev/null || true)"
    if [[ -n "$agent_surface" ]]; then
        _cmux_tree_json "$ws_ref" \
            | jq -r --arg agent "$agent_surface" '
                .windows[].workspaces[].panes[]
                | select(all(.surfaces[]?; .ref != $agent))
                | .ref
              ' 2>/dev/null \
            | head -1
        return
    fi

    _cmux_tree_json "$ws_ref" \
        | jq -r '[.windows[].workspaces[].panes[].ref] | .[1] // empty' 2>/dev/null
}

_cmux_new_surface_in_pane() {
    local ws_ref="$1" pane="$2" type="$3" url="$4" command="$5"
    local raw sid args
    args=(new-surface --workspace "$ws_ref" --pane "$pane" --type "$type" --focus false)
    [[ "$type" == "browser" && -n "$url" ]] && args+=(--url "$url")
    raw="$(cmux "${args[@]}" 2>&1)"
    sid="$(printf '%s' "$raw" | _cmux_surface_id_from_output)"
    [[ -n "$sid" ]] || sid="$(printf '%s' "$raw" | grep -oE 'surface:[0-9]+' | head -1)"
    if [[ -z "$sid" ]]; then
        echo "surface_create_failed: $raw" >&2
        return 1
    fi
    if [[ "$type" != "browser" && -n "$command" ]]; then
        _cmux_send_command_to_surface "$ws_ref" "$sid" "$command" || true
    fi
    echo "$sid"
}

_cmux_create_surface() {
    local ws_ref="$1" type="$2" title="$3" url="$4" command="$5" direction="${6:-down}" placement="${7:-right}"
    local raw="" sid="" pane="" split_surface=""

    pane="$(_cmux_pane_for_placement "$ws_ref" "$placement" 2>/dev/null || true)"
    if [[ -n "$pane" ]]; then
        if [[ "$placement" == "left" && "$type" == "terminal" ]]; then
            sid="$(_cmux_first_terminal_surface_in_pane "$ws_ref" "$pane" 2>/dev/null || true)"
            if [[ -n "$sid" ]]; then
                _cmux_send_command_to_surface "$ws_ref" "$sid" "$command" || true
                [[ -n "$title" ]] && cmux rename-tab --workspace "$ws_ref" --surface "$sid" "$title" >/dev/null 2>&1 || true
                echo "$sid"
                return 0
            fi
        fi
        sid="$(_cmux_new_surface_in_pane "$ws_ref" "$pane" "$type" "$url" "$command")" || return 1
        [[ -n "$title" ]] && cmux rename-tab --workspace "$ws_ref" --surface "$sid" "$title" >/dev/null 2>&1 || true
        echo "$sid"
        return 0
    fi

    if [[ "$placement" == "right" ]]; then
        local args=(new-pane --direction right --workspace "$ws_ref" --type "$type" --focus false)
        [[ "$type" == "browser" && -n "$url" ]] && args+=(--url "$url")
        raw="$(cmux "${args[@]}" 2>&1)"
    else
        raw="$(cmux new-split "$direction" --workspace "$ws_ref" 2>&1)"
    fi
    split_surface="$(printf '%s' "$raw" | _cmux_surface_id_from_output)"
    [[ -n "$split_surface" ]] || split_surface="$(printf '%s' "$raw" | grep -oE 'surface:[^[:space:]",}]+' | head -1)"
    if [[ -n "$split_surface" ]]; then
        pane="$(printf '%s' "$raw" | _cmux_pane_id_from_output)"
        [[ -n "$pane" ]] || pane="$(_cmux_pane_for_surface "$ws_ref" "$split_surface")"
        if [[ "$type" == "terminal" ]]; then
            sid="$split_surface"
            _cmux_send_command_to_surface "$ws_ref" "$sid" "$command" || true
        elif [[ "$placement" == "right" ]]; then
            sid="$split_surface"
        elif [[ -n "$pane" ]]; then
            sid="$(_cmux_new_surface_in_pane "$ws_ref" "$pane" "$type" "$url" "$command")" || return 1
            cmux close-surface --workspace "$ws_ref" --surface "$split_surface" >/dev/null 2>&1 || true
        fi
    fi
    if [[ -z "$sid" ]]; then
        echo "surface_create_failed: $raw" >&2
        return 1
    fi
    [[ -n "$title" ]] && cmux rename-tab --workspace "$ws_ref" --surface "$sid" "$title" >/dev/null 2>&1 || true
    echo "$sid"
}

_cmux_ensure_surface() {
    local ws_ref="$1" semantic="$2" type="$3" purpose="$4"
    shift 4
    local title="$semantic" url="" command="" agent="" direction="down" placement="" existing sid
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --title) title="${2:-}"; shift 2 ;;
            --url) url="${2:-}"; shift 2 ;;
            --command) command="${2:-}"; shift 2 ;;
            --agent) agent="${2:-}"; shift 2 ;;
            --direction) direction="${2:-down}"; shift 2 ;;
            --placement) placement="${2:-}"; shift 2 ;;
            *) echo "_cmux_ensure_surface: unknown arg: $1" >&2; return 2 ;;
        esac
    done
    [[ -n "$placement" ]] || placement="$(_cmux_default_placement "$semantic")"

    existing="$(_cmux_surface_from_metadata "$ws_ref" "$semantic" 2>/dev/null || true)"
    if [[ -n "$existing" ]]; then
        sid="$(jq -r '.surface_id // empty' <<< "$existing")"
        [[ -n "$title" ]] && cmux rename-tab --workspace "$ws_ref" --surface "$sid" "$title" >/dev/null 2>&1 || true
        if [[ "$type" == "browser" && -n "$url" ]]; then
            cmux browser "$sid" navigate "$url" >/dev/null 2>&1 || true
        fi
        _cmux_record_surface "$ws_ref" "$semantic" "$sid" "$type" "$purpose" "$title" "$url" "$agent" "$placement" || true
        echo "$sid"
        return 0
    fi

    sid="$(_cmux_create_surface "$ws_ref" "$type" "$title" "$url" "$command" "$direction" "$placement")" || return 1
    _cmux_record_surface "$ws_ref" "$semantic" "$sid" "$type" "$purpose" "$title" "$url" "$agent" "$placement" || true
    echo "$sid"
}

_cmux_send_to_surface() {
    local ws_ref="$1" semantic="$2" text="$3" surface_json sid type
    surface_json="$(_cmux_surface_from_metadata "$ws_ref" "$semantic" 2>/dev/null)" || {
        echo "surface_not_found: $semantic" >&2
        return 1
    }
    sid="$(jq -r '.surface_id // empty' <<< "$surface_json")"
    type="$(jq -r '.type // empty' <<< "$surface_json")"
    [[ "$type" == "terminal" || "$type" == "agent" ]] || {
        echo "surface_not_terminal: $semantic" >&2
        return 2
    }
    cmux send --workspace "$ws_ref" --surface "$sid" "$text" >/dev/null 2>&1
    cmux send-key --workspace "$ws_ref" --surface "$sid" enter >/dev/null 2>&1
}

_cmux_close_surface() {
    local ws_ref="$1" semantic="$2" surface_json sid
    surface_json="$(_cmux_surface_from_metadata "$ws_ref" "$semantic" 2>/dev/null || true)"
    if [[ -n "$surface_json" ]]; then
        sid="$(jq -r '.surface_id // empty' <<< "$surface_json")"
        [[ -n "$sid" ]] && cmux close-surface --workspace "$ws_ref" --surface "$sid" >/dev/null 2>&1 || true
    fi
    _cmux_metadata_clear "$ws_ref" "$(_cmux_surface_key "$semantic")"
}

mux_task_status_set() {
    local project_id="$1" task_id="$2" status_text="$3" icon="$4" color="$5"
    local ws_ref
    ws_ref="$(_cmux_task_workspace_ref "$project_id" "$task_id" 2>/dev/null || true)"
    [[ -n "$ws_ref" ]] || {
        echo "workspace_not_found: project=$project_id task=$task_id" >&2
        return 1
    }
    cmux set-status task_state "$status_text" \
        --icon "$icon" --color "$color" \
        --workspace "$ws_ref" >/dev/null || return
    echo "$ws_ref"
}

_cmux_port_is_free() {
    local candidate="$1"
    if command -v lsof >/dev/null 2>&1; then
        ! lsof -nP -iTCP:"$candidate" -sTCP:LISTEN >/dev/null 2>&1
        return
    fi

    if command -v nc >/dev/null 2>&1; then
        ! nc -z 127.0.0.1 "$candidate" >/dev/null 2>&1
        return
    fi

    return 0
}

_cmux_dashboard_ready() {
    local port="$1"
    curl -fsS "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1
}

_cmux_pick_dashboard_port() {
    local base="${CRAFT_DASHBOARD_PORT:-27434}"
    local candidate

    if [[ -n "${CRAFT_DASHBOARD_PORT:-}" ]]; then
        echo "$base"
        return
    fi

    for candidate in $(seq "$base" $((base + 50))); do
        if _cmux_port_is_free "$candidate"; then
            echo "$candidate"
            return
        fi
    done

    echo "$base"
}

_cmux_ensure_dashboard_server() {
    local project_dir="$1"
    local state_dir="$project_dir/.state/dashboard"
    local pid_file="$state_dir/pid"
    local port_file="$state_dir/port"
    local url_file="$state_dir/url"
    local log_file="$state_dir/server.log"
    local pid port url

    [[ -n "${DASHBOARD_CMD:-}" ]] || return 1
    command -v curl >/dev/null 2>&1 || {
        echo "ensure_session: curl not found; skipping web dashboard readiness check" >&2
        return 1
    }

    mkdir -p "$state_dir"

    if [[ -f "$pid_file" && -f "$port_file" ]]; then
        pid="$(cat "$pid_file" 2>/dev/null || true)"
        port="$(cat "$port_file" 2>/dev/null || true)"
        if [[ -n "$pid" && -n "$port" ]] && kill -0 "$pid" >/dev/null 2>&1 && _cmux_dashboard_ready "$port"; then
            url="http://127.0.0.1:${port}"
            echo "$url" > "$url_file"
            echo "$url"
            return 0
        fi
    fi

    port="$(_cmux_pick_dashboard_port)"
    url="http://127.0.0.1:${port}"

    # Keep Bun as a direct child of the orchestrator process so the dashboard
    # can still call the cmux CLI for focus actions.
    (
        export PROJECT_DIR CRAFT_ROOT
        export CRAFT_DASHBOARD_PORT="$port"
        export CRAFT_DASHBOARD_URL="$url"
        bash -lc "$DASHBOARD_CMD"
    ) >"$log_file" 2>&1 &
    echo "$!" > "$pid_file"

    for _ in $(seq 1 30); do
        if _cmux_dashboard_ready "$port"; then
            echo "$port" > "$port_file"
            echo "$url" > "$url_file"
            echo "$url"
            return 0
        fi
        sleep 0.25
    done

    echo "ensure_session: web dashboard did not become ready at $url (see $log_file)" >&2
    return 1
}

_cmux_pane_for_surface() {
    local ws_ref="$1" surface="$2"
    cmux tree --workspace "$ws_ref" --json 2>/dev/null \
        | jq -r --arg s "$surface" '
            .windows[].workspaces[].panes[]
            | select(.surfaces[]? | (.ref // .id // .surface_id // .surfaceId) == $s)
            | .ref
          ' 2>/dev/null \
        | head -1
}

_cmux_left_dashboard_pane() {
    local ws_ref="$1"
    local surface pane

    surface=$(_mux_surface_by_tab_title "$ws_ref" "orchestrator")
    if [[ -n "$surface" ]]; then
        pane=$(_cmux_pane_for_surface "$ws_ref" "$surface")
        [[ -n "$pane" ]] && { echo "$pane"; return; }
    fi

    cmux tree --workspace "$ws_ref" --json 2>/dev/null \
        | jq -r '
            .windows[].workspaces[].panes[]
            | select(.surfaces[]? | .type == "terminal" and .title != "architect")
            | .ref
          ' 2>/dev/null \
        | head -1
}

_cmux_ensure_dashboard_surface() {
    local ws_ref="$1" project_dir="$2" url="$3"
    local sid="" existing

    existing="$(_cmux_surface_from_metadata "$ws_ref" "dashboard" 2>/dev/null || true)"
    if [[ -n "$existing" ]]; then
        sid="$(jq -r '.surface_id // empty' <<< "$existing")"
    fi
    if [[ -z "$sid" ]]; then
        sid="$(_cmux_dashboard_surface_by_url "$ws_ref" "$url" 2>/dev/null || true)"
    fi

    if [[ -n "$sid" ]]; then
        cmux rename-tab --workspace "$ws_ref" --surface "$sid" "dashboard" >/dev/null 2>&1 || true
        cmux browser "$sid" navigate "$url" >/dev/null 2>&1 || true
        _cmux_record_surface "$ws_ref" "dashboard" "$sid" "browser" "dashboard" "dashboard" "$url" "" "left" || true
    else
        sid="$(_cmux_ensure_surface "$ws_ref" "dashboard" "browser" "dashboard" \
            --title "dashboard" \
            --url "$url" \
            --placement left)" || {
            echo "ensure_session: failed to create web dashboard browser surface" >&2
            return 1
        }
    fi
    _cmux_prune_dashboard_surfaces "$ws_ref" "$url" "$sid"

    if [[ "${CMUX_FOCUS_DASHBOARD:-}" == "1" ]]; then
        _cmux_focus_surface_ui "$ws_ref" "$sid" >/dev/null 2>&1 || true
    fi
}

_cmux_dashboard_surface_refs_by_url() {
    local ws_ref="$1" url="$2"
    local origin port
    origin="$(echo "$url" | sed -E 's#^(https?://[^/?#]+).*#\1#')"
    port="$(echo "$origin" | sed -nE 's#^https?://(localhost|127\.0\.0\.1):([0-9]+)$#\2#p')"
    cmux tree --workspace "$ws_ref" --json 2>/dev/null \
        | jq -r --arg origin "$origin" --arg port "$port" '
            def origin:
              try capture("^(?<origin>https?://[^/?#]+)").origin catch .;
            def local_port:
              try capture("^https?://(localhost|127[.]0[.]0[.]1):(?<port>[0-9]+)").port catch "";
            .windows[].workspaces[].panes[].surfaces[]
            | select(.type == "browser")
            | select(
                if $port != "" then ((.url // "") | local_port) == $port
                else ((.url // "") | origin) == $origin
                end
              )
            | .ref // .id // .surface_id // .surfaceId // empty
          ' 2>/dev/null
}

_cmux_dashboard_surface_by_url() {
    _cmux_dashboard_surface_refs_by_url "$1" "$2" | head -1
}

_cmux_prune_dashboard_surfaces() {
    local ws_ref="$1" url="$2" keep="$3" ref
    while IFS= read -r ref; do
        [[ -n "$ref" && "$ref" != "$keep" ]] || continue
        cmux close-surface --workspace "$ws_ref" --surface "$ref" >/dev/null 2>&1 || true
    done < <(_cmux_dashboard_surface_refs_by_url "$ws_ref" "$url")
}

_cmux_existing_dashboard_url() {
    local ws_ref="$1"
    local candidate origin port

    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        origin="$(echo "$candidate" | sed -E 's#^(https?://[^/?#]+).*#\1#')"
        port="$(echo "$origin" | sed -nE 's#^https?://(localhost|127\.0\.0\.1):([0-9]+)$#\2#p')"
        [[ -n "$port" ]] || continue
        if _cmux_dashboard_ready "$port"; then
            echo "$origin"
            return 0
        fi
    done < <(
        cmux tree --workspace "$ws_ref" --json 2>/dev/null \
            | jq -r '
                .windows[].workspaces[].panes[].surfaces[]
                | select(.type == "browser")
                | .url // empty
              ' 2>/dev/null
    )

    return 1
}

_cmux_ensure_project_dashboard() {
    local ws_ref="$1" project_dir="$2"
    local state_dir="$project_dir/.state/dashboard"
    local url port

    [[ -n "${project_dir:-}" ]] || return 0
    url="$(_cmux_existing_dashboard_url "$ws_ref" || true)"
    if [[ -n "$url" ]]; then
        mkdir -p "$state_dir"
        port="$(echo "$url" | sed -nE 's#^https?://(localhost|127\.0\.0\.1):([0-9]+)$#\2#p')"
        [[ -n "$port" ]] && echo "$port" > "$state_dir/port"
        echo "$url" > "$state_dir/url"
    else
        url=$(_cmux_ensure_dashboard_server "$project_dir") || return 0
    fi
    _cmux_ensure_dashboard_surface "$ws_ref" "$project_dir" "$url" || true
}

_mux_ws_ref() {
    local session="$1" project_id task_id
    project_id="$(_cmux_session_project_id "$session")"
    task_id="$(_cmux_session_task_id "$session" "$project_id" 2>/dev/null || true)"
    if [[ -n "$task_id" ]]; then
        _cmux_task_workspace_ref "$project_id" "$task_id"
    else
        _cmux_project_workspace_ref "$project_id"
    fi
}

# Attached-only helper for optional UI placement. Supervisor logic must not
# depend on cmux window movement because detached snapshots have no Swift UI
# window to focus or mutate.
_mux_ws_window() {
    local session="$1" ws_ref
    ws_ref="$(_mux_ws_ref "$session")"
    [[ -n "$ws_ref" ]] || return 1
    cmux tree --all --json 2>/dev/null \
        | jq -r --arg ws "$ws_ref" '
            .windows[]
            | select(.workspaces[]? | (.ref // .id // .workspace_id // .workspaceId) == $ws)
            | .ref
          ' 2>/dev/null \
        | head -1
}

_cmux_create_task_workspace() {
    local task_dir="$1" title="$2"
    local raw ws_ref destination

    if _cmux_running_in_remote_workspace; then
        destination="$(_cmux_same_host_destination)"
        raw="$(cmux ssh "$destination" ${task_dir:+--cwd "$task_dir"} --name "$title" --json 2>&1)"
        ws_ref="$(printf '%s' "$raw" | _cmux_workspace_id_from_output)"
        if [[ -z "$ws_ref" ]]; then
            echo "_cmux_create_task_workspace: failed to create remote cmux task workspace: $raw" >&2
            return 1
        fi
        echo "$ws_ref"
        return 0
    fi

    raw=$(cmux new-workspace ${task_dir:+--working-directory "$task_dir"} 2>&1)
    ws_ref="$(printf '%s' "$raw" | _cmux_workspace_id_from_output)"
    [[ -n "$ws_ref" ]] || ws_ref=$(echo "$raw" | grep -oE 'workspace:[0-9]+' | head -1)
    if [[ -z "$ws_ref" ]]; then
        echo "_cmux_create_task_workspace: failed to create cmux workspace: $raw" >&2
        return 1
    fi
    echo "$ws_ref"
}

_cmux_create_project_workspace() {
    local project_dir="$1" title="$2" command="${3:-}"
    local raw ws_ref destination

    if _cmux_running_in_remote_workspace; then
        destination="$(_cmux_same_host_destination)"
        local args=(ssh "$destination")
        [[ -n "$project_dir" ]] && args+=(--cwd "$project_dir")
        [[ -n "$title" ]] && args+=(--name "$title")
        args+=(--json)
        raw="$(cmux "${args[@]}" 2>&1)"
        ws_ref="$(printf '%s' "$raw" | _cmux_workspace_id_from_output)"
        if [[ -z "$ws_ref" ]]; then
            echo "_cmux_create_project_workspace: failed to create remote cmux project workspace: $raw" >&2
            return 1
        fi
        printf '%s\n' "$raw"
        return 0
    fi

    raw="$(cmux new-workspace --working-directory "$project_dir" 2>&1)"
    ws_ref="$(printf '%s' "$raw" | _cmux_workspace_id_from_output)"
    [[ -n "$ws_ref" ]] || ws_ref="$(echo "$raw" | grep -oE 'workspace:[0-9]+' | head -1)"
    if [[ -z "$ws_ref" ]]; then
        echo "_cmux_create_project_workspace: failed to create cmux workspace: $raw" >&2
        return 1
    fi
    printf '%s\n' "$raw"
}

mux_bootstrap_orchestrator() {
    local project_name="$1" project_dir="$2" command="$3"
    local title="${CMUX_PREFIX}-${project_name}" ws_ref raw surface_id
    ws_ref="$(_cmux_project_workspace_ref "$project_name" 2>/dev/null || true)"
    if [[ -z "$ws_ref" ]]; then
        raw="$(_cmux_create_project_workspace "$project_dir" "$title" "$command")" || return 1
        ws_ref="$(printf '%s' "$raw" | _cmux_workspace_id_from_output)"
        [[ -n "$ws_ref" ]] || ws_ref="$(echo "$raw" | grep -oE 'workspace:[0-9]+' | head -1)"
        if [[ -z "$ws_ref" ]]; then
            echo "mux_bootstrap_orchestrator: failed to create cmux workspace: $raw" >&2
            return 1
        fi
    fi
    _cmux_write_workspace_identity "$ws_ref" "$project_name" "$project_dir" || {
        echo "mux_bootstrap_orchestrator: failed to write cmux workspace metadata for project=$project_name" >&2
        return 1
    }
    cmux rename-workspace --workspace "$ws_ref" "$title" >/dev/null 2>&1 || true
    surface_id="$(printf '%s' "$raw" | _cmux_surface_id_from_output)"
    if [[ -n "$surface_id" ]]; then
        _cmux_record_surface "$ws_ref" "orchestrator" "$surface_id" "terminal" "orchestrator" "orchestrator" "" "" "left" || true
        cmux rename-tab --workspace "$ws_ref" --surface "$surface_id" "orchestrator" >/dev/null 2>&1 || true
        _cmux_send_command_to_surface "$ws_ref" "$surface_id" "$command" || true
        cmux select-workspace --workspace "$ws_ref" >/dev/null 2>&1 || true
        echo "$surface_id"
        return 0
    fi
    surface_id="$(_cmux_ensure_surface "$ws_ref" "orchestrator" "terminal" "orchestrator" \
        --title "orchestrator" \
        --command "$command" \
        --direction down)" || return 1
    cmux select-workspace --workspace "$ws_ref" >/dev/null 2>&1 || true
    echo "$surface_id"
}

mux_replace_orchestrator_workspace() {
    local project_name="$1" project_dir="$2" command="$3"
    local title="${CMUX_PREFIX}-${project_name}" old_ws new_ws raw surface_id

    old_ws="$(_cmux_project_workspace_ref "$project_name" 2>/dev/null || true)"
    raw="$(_cmux_create_project_workspace "$project_dir" "$title" "$command")" || return 1
    new_ws="$(printf '%s' "$raw" | _cmux_workspace_id_from_output)"
    [[ -n "$new_ws" ]] || new_ws="$(echo "$raw" | grep -oE 'workspace:[0-9]+' | head -1)"
    if [[ -z "$new_ws" ]]; then
        echo "mux_replace_orchestrator_workspace: failed to create cmux workspace: $raw" >&2
        return 1
    fi

    _cmux_write_workspace_identity "$new_ws" "$project_name" "$project_dir" || {
        echo "mux_replace_orchestrator_workspace: failed to write cmux workspace metadata for project=$project_name" >&2
        return 1
    }
    cmux rename-workspace --workspace "$new_ws" "$title" >/dev/null 2>&1 || true
    cmux workspace-action --workspace "$new_ws" --action pin >/dev/null 2>&1 || true

    if [[ -n "$old_ws" && "$old_ws" != "$new_ws" ]]; then
        _cmux_clear_workspace_identity "$old_ws"
    fi

    surface_id="$(printf '%s' "$raw" | _cmux_surface_id_from_output)"
    if [[ -n "$surface_id" ]]; then
        _cmux_record_surface "$new_ws" "orchestrator" "$surface_id" "terminal" "orchestrator" "orchestrator" "" "" "left" || true
        cmux rename-tab --workspace "$new_ws" --surface "$surface_id" "orchestrator" >/dev/null 2>&1 || true
        _cmux_send_command_to_surface "$new_ws" "$surface_id" "$command" || true
    else
        surface_id="$(_cmux_ensure_surface "$new_ws" "orchestrator" "terminal" "orchestrator" \
            --title "orchestrator" \
            --command "$command" \
            --direction down)" || return 1
    fi

    cmux select-workspace --workspace "$new_ws" >/dev/null 2>&1 || true
    if [[ -n "$old_ws" && "$old_ws" != "$new_ws" ]]; then
        _cmux_close_workspace_async "$old_ws"
    fi
    echo "$surface_id"
}

# Ensure the cmux workspace exists, with orchestrator + architect surfaces.
# Returns the workspace title (stable identifier; other functions look up the
# ref internally as needed).
ensure_session() {
    local project_name="$1"
    local project_dir="$2"
    local title="${CMUX_PREFIX}-${project_name}"

    [[ -n "${PROJECT_NAME:-}" ]] || PROJECT_NAME="$project_name"
    local ws_ref
    ws_ref="$(_cmux_project_workspace_ref "$project_name" 2>/dev/null || true)"

    if [[ -z "$ws_ref" ]]; then
        local raw
        raw="$(_cmux_create_project_workspace "$project_dir" "$title")" || return 1
        ws_ref="$(printf '%s' "$raw" | _cmux_workspace_id_from_output)"
        [[ -n "$ws_ref" ]] || ws_ref=$(echo "$raw" | grep -oE 'workspace:[0-9]+' | head -1)
        if [[ -z "$ws_ref" ]]; then
            echo "ensure_session: failed to create cmux workspace: $raw" >&2
            return 1
        fi
        cmux rename-workspace --workspace "$ws_ref" "$title" >/dev/null 2>&1 || true
    fi
    _cmux_write_workspace_identity "$ws_ref" "$project_name" "$project_dir" || {
        echo "ensure_session: failed to write cmux workspace metadata for project=$project_name" >&2
        return 1
    }
    cmux rename-workspace --workspace "$ws_ref" "$title" >/dev/null 2>&1 || true

    # Pin the project workspace so it stays anchored at the top of the cmux
    # sidebar even as task workspaces are created/closed beneath it. Without
    # this, `cmux new-workspace` inserts new task workspaces above it and
    # the operator loses sight of the dashboard/architect/orchestrator tabs.
    # Idempotent — pin on an already-pinned workspace is a no-op.
    cmux workspace-action --workspace "$ws_ref" --action pin >/dev/null 2>&1 || true

    _cmux_ensure_project_dashboard "$ws_ref" "$project_dir"

    if [[ "${CMUX_ENSURE_ARCHITECT:-}" == "1" && -n "${project_dir:-}" ]] && ! _cmux_surface_from_metadata "$ws_ref" "architect" >/dev/null 2>&1; then
        local skill_file="${project_dir}/.claude/commands/init-architect.md"
        local architect_agent="${ARCHITECT_AGENT:-claude}"
        local architect_agent_model="${ARCHITECT_AGENT_MODEL:-}"
        local cmd
        cmd=$(provider_architect_cmd "$architect_agent" "$skill_file" "$project_dir" "$architect_agent_model")

        _cmux_ensure_surface "$ws_ref" "architect" "terminal" "architect" \
            --title "architect" \
            --command "$cmd" \
            --agent "$architect_agent" \
            --direction right >/dev/null || true
    fi

    echo "$title"
}

# Ensure a per-task cmux workspace exists. Returns the *structured* portion
# of the title (e.g. `craft-llm-classification-task-015`) for compatibility
# with existing runtime session files. The actual cmux workspace identity lives
# in hidden metadata, not in this title.
#
# Args: <project_name> <task_id> [task_dir] [human_title]
ensure_task_session() {
    local project_name="$1" task_id="$2" task_dir="${3:-}" human_title="${4:-}"
    local structured="${CMUX_PREFIX}-${project_name}-${task_id}"
    local title="$structured"
    [[ -n "$human_title" ]] && title="${structured} · ${human_title}"
    [[ -n "${PROJECT_NAME:-}" ]] || PROJECT_NAME="$project_name"

    local ws_ref
    ws_ref="$(_cmux_task_workspace_ref "$project_name" "$task_id" 2>/dev/null || true)"
    if [[ -z "$ws_ref" ]]; then
        ws_ref="$(_cmux_create_task_workspace "$task_dir" "$title")" || return 1
    fi
    local project_dir="${PROJECT_DIR:-}"
    if [[ -z "$project_dir" && -n "$task_dir" ]]; then
        project_dir="$(cd "$task_dir/../.." 2>/dev/null && pwd -P || true)"
    fi
    _cmux_write_workspace_identity "$ws_ref" "$project_name" "$project_dir" "$task_id" "$task_dir" || {
        echo "ensure_task_session: failed to write cmux workspace metadata for project=$project_name task=$task_id" >&2
        return 1
    }
    # Workspace titles are operator-facing only. Refresh them for readability,
    # but never use them as lookup state.
    cmux rename-workspace --workspace "$ws_ref" "$title" >/dev/null 2>&1 || true

    # Co-locate the task workspace in the same cmux window as the project
    # workspace. `cmux new-workspace` has no --window flag and picks "current
    # window" based on GUI focus, so without this the task workspace can land
    # in a different window than the project — confusing for the operator.
    local task_win project_win
    task_win=$(_mux_ws_window "$structured")
    project_win=$(_mux_ws_window "${CMUX_PREFIX}-${project_name}")
    if [[ -n "$task_win" && -n "$project_win" && "$task_win" != "$project_win" ]]; then
        cmux move-workspace-to-window --workspace "$ws_ref" --window "$project_win" >/dev/null 2>&1 || true
    fi

    echo "$structured"
}

spawn_task_pane() {
    local session="$1" task_id="$2" prompt_file="$3" work_dir="$4"
    local agent="${5:-claude}"
    local agent_model="${6:-}"

    local ws_ref
    ws_ref=$(_mux_ws_ref "$session")
    [[ -n "$ws_ref" ]] || { echo "spawn_task_pane: no workspace titled '$session'" >&2; return 1; }

    local cmd
    cmd=$(provider_task_cmd "$agent" "$prompt_file" "$work_dir" "$agent_model")

    local surface_id
    surface_id="$(_cmux_ensure_surface "$ws_ref" "agent" "terminal" "agent" \
        --title "$task_id" \
        --command "$cmd" \
        --agent "$agent" \
        --direction down)" || return 1

    echo "$surface_id"
}

_mux_surface_by_tab_title() {
    local ws_ref="$1" semantic="$2" surface_json
    surface_json="$(_cmux_surface_from_metadata "$ws_ref" "$semantic" 2>/dev/null || true)"
    [[ -n "$surface_json" ]] || return 1
    jq -r '.surface_id // empty' <<< "$surface_json"
}

pane_is_running() {
    local session="$1" _task_id="$2"
    local ws_ref
    ws_ref=$(_mux_ws_ref "$session")
    [[ -n "$ws_ref" ]] || return 1

    _cmux_surface_from_metadata "$ws_ref" "agent" >/dev/null 2>&1
}

kill_task_pane() {
    local session="$1" _task_id="$2"
    local ws_ref
    ws_ref=$(_mux_ws_ref "$session")
    [[ -n "$ws_ref" ]] || return 0

    _cmux_close_surface "$ws_ref" "agent"
}

# Update the orchestrator display (no-op for cmux — dashboard renders in-terminal).
update_orchestrator_display() {
    local session="$1" status_text="$2"
    if [[ -n "$status_text" ]]; then
        local ws_ref
        ws_ref=$(_mux_ws_ref "$session")
        [[ -n "$ws_ref" ]] && cmux set-status "craft" "$status_text" --workspace "$ws_ref" >/dev/null 2>&1 || true
    fi
}

_mux_lookup_ref() {
    local session="$1" name="$2"
    local ws_ref
    ws_ref=$(_mux_ws_ref "$session")
    [[ -n "$ws_ref" ]] || return 1
    _mux_surface_by_tab_title "$ws_ref" "$(_cmux_semantic_for_pane "$session" "$name")"
}

_cmux_semantic_for_pane() {
    local session="$1" name="$2" project_id task_id
    project_id="$(_cmux_session_project_id "$session")"
    task_id="$(_cmux_session_task_id "$session" "$project_id" 2>/dev/null || true)"
    if [[ -n "$task_id" && "$name" == "$task_id" ]]; then
        echo "agent"
    else
        echo "$name"
    fi
}

_mux_surface_alive() {
    local session="$1" sid="$2"
    local ws_ref
    ws_ref=$(_mux_ws_ref "$session")
    [[ -n "$ws_ref" ]] || return 1
    _cmux_surface_exists "$ws_ref" "$sid"
}

mux_spawn_named_pane() {
    local session="$1" name="$2" cwd="$3" cmd="$4"

    local ws_ref
    ws_ref=$(_mux_ws_ref "$session")
    [[ -n "$ws_ref" ]] || { echo "mux-cmux: no workspace titled '$session'" >&2; return 1; }

    local sid
    sid="$(_cmux_ensure_surface "$ws_ref" "$name" "terminal" "$name" \
        --title "$name" \
        --command "cd '$cwd' && $cmd" \
        --direction down)" || return 1
    echo "$sid"
}

mux_send_to_pane() {
    local session="$1" name="$2" text="$3"
    local ws_ref
    ws_ref=$(_mux_ws_ref "$session")
    [[ -n "$ws_ref" ]] || { echo "mux-cmux: no workspace titled '$session'" >&2; return 1; }
    local sid
    local semantic
    semantic="$(_cmux_semantic_for_pane "$session" "$name")"
    sid=$(_mux_lookup_ref "$session" "$name")
    [[ -n "$sid" ]] || { echo "mux-cmux: no pane named '$name' in '$session'" >&2; return 1; }
    _cmux_send_to_surface "$ws_ref" "$semantic" "$text"
}

mux_pane_exists() {
    local session="$1" name="$2"
    local sid
    sid=$(_mux_lookup_ref "$session" "$name")
    [[ -n "$sid" ]] || return 1
    _mux_surface_alive "$session" "$sid"
}

mux_kill_named_pane() {
    local session="$1" name="$2"
    local ws_ref
    ws_ref=$(_mux_ws_ref "$session")
    [[ -n "$ws_ref" ]] || return 1
    local sid
    sid=$(_mux_lookup_ref "$session" "$name")
    _cmux_close_surface "$ws_ref" "$(_cmux_semantic_for_pane "$session" "$name")"
}

_cmux_pane_with_browser() {
    local ws_ref="$1"
    cmux tree --workspace "$ws_ref" --json 2>/dev/null \
        | jq -r '
            .windows[].workspaces[].panes[]
            | select(.surfaces[]? | .type == "browser")
            | .ref
          ' 2>/dev/null \
        | head -1
}

_cmux_new_browser_surface_right() {
    local ws_ref="$1" url="$2"
    local pane out sid split_surface split_pane

    pane="$(_cmux_pane_with_browser "$ws_ref")"
    if [[ -n "$pane" ]]; then
        out="$(cmux new-surface --type browser --pane "$pane" --url "$url" 2>&1)"
        sid="$(echo "$out" | grep -oE 'surface:[0-9]+' | head -1)"
        [[ -n "$sid" ]] && { echo "$sid"; return 0; }
    fi

    out="$(cmux new-split right --workspace "$ws_ref" 2>&1)"
    split_surface="$(echo "$out" | grep -oE 'surface:[0-9]+' | head -1)"
    if [[ -n "$split_surface" ]]; then
        split_pane="$(_cmux_pane_for_surface "$ws_ref" "$split_surface")"
        if [[ -n "$split_pane" ]]; then
            out="$(cmux new-surface --type browser --pane "$split_pane" --url "$url" 2>&1)"
            sid="$(echo "$out" | grep -oE 'surface:[0-9]+' | head -1)"
            cmux close-surface --workspace "$ws_ref" --surface "$split_surface" >/dev/null 2>&1 || true
            [[ -n "$sid" ]] && { echo "$sid"; return 0; }
        fi
    fi

    out="$(cmux new-surface --type browser --workspace "$ws_ref" --url "$url" 2>&1)"
    sid="$(echo "$out" | grep -oE 'surface:[0-9]+' | head -1)"
    [[ -n "$sid" ]] && { echo "$sid"; return 0; }
    echo "surface_open_failed: $out" >&2
    return 1
}

_cmux_task_workspace_label() {
    local project_dir="$1" task_id="$2"
    echo "${CMUX_PREFIX:-craft}-$(basename "$project_dir")-${task_id}"
}

_cmux_task_workspace_ref_for_project_dir() {
    local project_dir="$1" task_id="$2"
    local project_id
    project_id="$(basename "$project_dir")"
    _cmux_task_workspace_ref "$project_id" "$task_id"
}

_cmux_task_workspace_lookup_item_for_project_dir() {
    local project_dir="$1" task_id="$2"
    local project_id
    project_id="$(basename "$project_dir")"
    _cmux_workspace_lookup_json_by_metadata \
        "craft:project-id=${project_id}" \
        "craft:task-id=${task_id}" \
        | _cmux_workspace_lookup_item_from_json
}

mux_task_workspace_state() {
    local project_dir="$1" task_id="$2" surface_id="${3:-agent}"
    local item ws_ref attached detached recorded surface_ref surface_exists=false
    item="$(_cmux_task_workspace_lookup_item_for_project_dir "$project_dir" "$task_id" 2>/dev/null || true)"
    if [[ -z "$item" ]]; then
        jq -n --arg task_id "$task_id" '{task_id:$task_id, exists:false, attached:false, detached:false}'
        return 0
    fi
    ws_ref="$(jq -r '.workspace_id // .workspaceId // .id // .workspace_ref // .workspaceRef // .ref // empty' <<< "$item")"
    attached="$(jq -r 'if .attached == true then "true" else "false" end' <<< "$item")"
    detached="$(jq -r 'if .detached == true then "true" elif .attached == false then "true" else "false" end' <<< "$item")"
    recorded="$(_cmux_surface_from_metadata "$ws_ref" "$surface_id" 2>/dev/null || true)"
    surface_ref="$(jq -r '.surface_id // .surface_ref // .ref // empty' <<< "${recorded:-null}" 2>/dev/null || true)"
    if [[ -n "$surface_ref" ]] && _cmux_surface_exists "$ws_ref" "$surface_ref"; then
        surface_exists=true
    fi
    jq -n \
        --arg task_id "$task_id" \
        --arg workspace_ref "$ws_ref" \
        --arg surface_ref "$surface_ref" \
        --argjson attached "$attached" \
        --argjson detached "$detached" \
        --argjson surface_exists "$surface_exists" \
        '{
          task_id: $task_id,
          exists: true,
          attached: $attached,
          detached: $detached,
          workspace_ref: $workspace_ref,
          surface_ref: $surface_ref,
          surface_exists: $surface_exists
        }'
}

mux_surface_open() {
    local project_dir="$1" task_id="$2" surface_id="$3"
    shift 3
    local url="" label="$surface_id" owner="craft" stage="" url_match="exact" kind="browser" placement=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --url) url="${2:-}"; shift 2 ;;
            --label) label="${2:-}"; shift 2 ;;
            --owner) owner="${2:-}"; shift 2 ;;
            --stage) stage="${2:-}"; shift 2 ;;
            --url-match) url_match="${2:-}"; shift 2 ;;
            --kind) kind="${2:-}"; shift 2 ;;
            --placement) placement="${2:-}"; shift 2 ;;
            *) echo "surface open: unknown arg: $1" >&2; return 2 ;;
        esac
    done
    [[ "$kind" == "browser" ]] || { echo "surface_unsupported_kind: $kind" >&2; return 2; }
    [[ -n "$url" ]] || { echo "surface open: --url is required" >&2; return 2; }

    local ws_ref sid
    ws_ref="$(_cmux_task_workspace_ref_for_project_dir "$project_dir" "$task_id" 2>/dev/null || true)"
    [[ -n "$ws_ref" ]] || { echo "workspace_not_found: $(_cmux_task_workspace_label "$project_dir" "$task_id")" >&2; return 1; }

    sid="$(_cmux_ensure_surface "$ws_ref" "$surface_id" "$kind" "$surface_id" \
        --title "$label" \
        --url "$url" \
        ${placement:+--placement "$placement"})" || return 1
    _cmux_surface_metadata_set "$ws_ref" "$sid" "craft:owner" "$owner" || true
    _cmux_surface_metadata_set "$ws_ref" "$sid" "craft:stage" "$stage" || true
    _cmux_surface_metadata_set "$ws_ref" "$sid" "craft:url_match" "$url_match" || true
    _cmux_focus_surface_ui "$ws_ref" "$sid" >/dev/null 2>&1 || true
    echo "$sid"
}

mux_surface_focus() {
    local project_dir="$1" task_id="$2" surface_id="$3"
    local attach_first="${4:-false}"
    local ws_ref recorded cached
    ws_ref="$(_cmux_task_workspace_ref_for_project_dir "$project_dir" "$task_id" 2>/dev/null || true)"
    [[ -n "$ws_ref" ]] || { echo "workspace_not_found: $(_cmux_task_workspace_label "$project_dir" "$task_id")" >&2; return 1; }
    if [[ "$attach_first" == "true" ]]; then
        ws_ref="$(_cmux_attach_workspace_ui "$ws_ref")" || return 1
    fi
    recorded="$(_cmux_surface_from_metadata "$ws_ref" "$surface_id" 2>/dev/null || true)"
    if [[ -n "$recorded" ]]; then
        cached="$(jq -r '.surface_id // empty' <<< "$recorded")"
        _cmux_focus_surface_ui "$ws_ref" "$cached" || return 1
        echo "$cached"
        return 0
    fi
    echo "surface_not_found: $surface_id" >&2
    return 4
}

mux_surface_close() {
    local project_dir="$1" task_id="$2" surface_id="$3"
    local ws_ref
    ws_ref="$(_cmux_task_workspace_ref_for_project_dir "$project_dir" "$task_id" 2>/dev/null || true)"
    if [[ -n "$ws_ref" ]]; then
        _cmux_close_surface "$ws_ref" "$surface_id"
    fi
}
