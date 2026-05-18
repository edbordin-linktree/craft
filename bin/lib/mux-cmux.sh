#!/usr/bin/env bash
# mux-cmux.sh — cmux multiplexer provider for the craft orchestrator
#
# Uses cmux workspaces and surfaces instead of tmux sessions and windows.
# Requires cmux to be running (it's a macOS GUI app, not a daemon).

# Requires bash 4+ (associative arrays in primitives, lowercase parameter expansion).
if [[ ${BASH_VERSINFO[0]:-0} -lt 4 ]]; then
    echo "mux-cmux.sh requires bash 4+ (you have ${BASH_VERSION:-unknown}). On macOS: 'brew install bash' then ensure /opt/homebrew/bin (or /usr/local/bin) is earlier on PATH than /bin." >&2
    return 1 2>/dev/null || exit 1
fi

# Workspace name prefix
CMUX_PREFIX="craft"

_cmux_craft_root() {
    if [[ -n "${CRAFT_ROOT:-}" ]]; then
        echo "$CRAFT_ROOT"
        return
    fi
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P
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
    local craft_root dashboard_dir pid port url

    craft_root="$(_cmux_craft_root)"
    dashboard_dir="$craft_root/plugins/orchestrator-skills/dashboard"

    [[ -f "$dashboard_dir/server.tsx" ]] || return 1
    command -v bun >/dev/null 2>&1 || {
        echo "ensure_session: bun not found; skipping web dashboard" >&2
        return 1
    }
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
    pushd "$dashboard_dir" >/dev/null || return 1
    bun server.tsx --project "$project_dir" --port "$port" >"$log_file" 2>&1 &
    echo "$!" > "$pid_file"
    popd >/dev/null || return 1

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
            | select(.surfaces[]? | .ref == $s)
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
    local state_dir="$project_dir/.state/dashboard"
    local surface_file="$state_dir/surface"
    local existing pane out sid orchestrator

    existing=$(cmux tree --workspace "$ws_ref" --json 2>/dev/null \
        | jq -r --arg u "$url" '
            .windows[].workspaces[].panes[].surfaces[]
            | select(.type == "browser"
                     and (.title == "dashboard" or ((.url // "") | startswith($u))))
            | .ref
          ' 2>/dev/null \
        | head -1)

    if [[ -n "$existing" ]]; then
        cmux browser "$existing" navigate "$url" >/dev/null 2>&1 || true
        cmux rename-tab --workspace "$ws_ref" --surface "$existing" "dashboard" >/dev/null 2>&1 || true
        echo "$existing" > "$surface_file"
        return 0
    fi

    pane="$(_cmux_left_dashboard_pane "$ws_ref")"
    if [[ -n "$pane" ]]; then
        out=$(cmux new-surface --type browser --pane "$pane" --url "$url" 2>&1)
    else
        out=$(cmux new-surface --type browser --workspace "$ws_ref" --url "$url" 2>&1)
    fi

    sid=$(echo "$out" | grep -oE 'surface:[0-9]+' | head -1)
    if [[ -z "$sid" ]]; then
        echo "ensure_session: failed to create web dashboard browser surface: $out" >&2
        return 1
    fi

    cmux rename-tab --workspace "$ws_ref" --surface "$sid" "dashboard" >/dev/null 2>&1 || true
    echo "$sid" > "$surface_file"

    orchestrator=$(_mux_surface_by_tab_title "$ws_ref" "orchestrator")
    [[ -n "$orchestrator" ]] && cmux focus-surface "$orchestrator" >/dev/null 2>&1 || true
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

# --- Workspace lookup ---
#
# The cmux CLI accepts `--workspace <id|ref|index>` but NOT title. We use the
# workspace title as the stable external identifier (it survives cmux restarts;
# refs do not), and translate title → ref internally on each call.

_mux_ws_ref() {
    # Print the workspace ref for a given title. Match exact OR by structured
    # prefix — so workspaces whose title has a human-readable suffix appended
    # (e.g. `craft-llm-classification-task-015 · Document dependabot omission`)
    # still resolve when called with the structured part alone.
    #
    # Must search across ALL cmux windows, not just the current one — the
    # orchestrator's shell is bound to one window, but `cmux new-workspace`
    # picks the window via GUI focus, so a task workspace can end up in a
    # different window than the orchestrator. `cmux list-workspaces` is
    # current-window-only; `cmux tree --all --json` gives the full view.
    local title="$1"
    cmux tree --all --json 2>/dev/null \
        | jq -r --arg t "$title" '
            .windows[].workspaces[]
            | select(.title == $t
                     or (.title | startswith($t + " "))
                     or (.title | startswith($t + "·")))
            | .ref
          ' 2>/dev/null \
        | head -1
}

# Print the window ref that contains a workspace whose title matches the
# given structured prefix. Mirrors _mux_ws_ref's prefix matching so that
# workspaces with human-readable suffixes (e.g.
# `craft-llm-classification-task-015 · Add a short …`) still resolve when
# looked up by the structured part alone — otherwise the co-locate-to-
# project-window logic in ensure_task_session no-ops and new task
# workspaces land in whichever cmux window has GUI focus.
_mux_ws_window() {
    local title="$1"
    cmux tree --all --json 2>/dev/null \
        | jq -r --arg t "$title" '
            .windows[]
            | select(.workspaces[]?
                | .title == $t
                  or (.title | startswith($t + " "))
                  or (.title | startswith($t + "·"))
              )
            | .ref
          ' 2>/dev/null \
        | head -1
}

# Ensure the cmux workspace exists, with orchestrator + architect surfaces.
# Returns the workspace title (stable identifier; other functions look up the
# ref internally as needed).
ensure_session() {
    local project_name="$1"
    local project_dir="$2"
    local title="${CMUX_PREFIX}-${project_name}"

    local ws_ref
    ws_ref=$(_mux_ws_ref "$title")

    if [[ -z "$ws_ref" ]]; then
        # `cmux new-workspace` takes --cwd / --command — NOT a positional title.
        # Capture the returned ref from "OK workspace:N" and rename to set title.
        local raw
        raw=$(cmux new-workspace --cwd "$project_dir" 2>&1)
        ws_ref=$(echo "$raw" | grep -oE 'workspace:[0-9]+' | head -1)
        if [[ -z "$ws_ref" ]]; then
            echo "ensure_session: failed to create cmux workspace: $raw" >&2
            return 1
        fi
        cmux rename-workspace --workspace "$ws_ref" "$title" >/dev/null 2>&1 || true
    fi

    # Pin the project workspace so it stays anchored at the top of the cmux
    # sidebar even as task workspaces are created/closed beneath it. Without
    # this, `cmux new-workspace` inserts new task workspaces above it and
    # the operator loses sight of the dashboard/architect/orchestrator tabs.
    # Idempotent — pin on an already-pinned workspace is a no-op.
    cmux workspace-action --workspace "$ws_ref" --action pin >/dev/null 2>&1 || true

    _cmux_ensure_project_dashboard "$ws_ref" "$project_dir"

    # Ensure an architect surface exists in this workspace. We check by tab
    # title rather than counting terminal surfaces — the project workspace
    # may already have other terminals (orchestrator, dashboard, ad-hoc
    # operator tabs), but as long as none of them is named "architect" we
    # still need to create one.
    local architect_exists=0
    if cmux tree --workspace "$ws_ref" --json 2>/dev/null \
        | jq -e '.windows[].workspaces[].panes[].surfaces[] | select(.title == "architect")' \
        >/dev/null 2>&1; then
        architect_exists=1
    fi

    if (( architect_exists == 0 )) && [[ -n "${project_dir:-}" ]]; then
        local skill_file="${project_dir}/.claude/commands/init-architect.md"
        local architect_agent="${ARCHITECT_AGENT:-claude}"
        local cmd
        cmd=$(provider_architect_cmd "$architect_agent" "$skill_file" "$project_dir")

        local arch_raw arch_surface
        arch_raw=$(cmux new-split right --workspace "$ws_ref" 2>&1)
        arch_surface=$(echo "$arch_raw" | grep -oE 'surface:[0-9]+' | head -1)

        if [[ -n "$arch_surface" ]]; then
            cmux rename-tab --workspace "$ws_ref" --surface "$arch_surface" "architect" >/dev/null 2>&1 || true
            cmux send --workspace "$ws_ref" --surface "$arch_surface" "$cmd" >/dev/null 2>&1 || true
            cmux send-key --workspace "$ws_ref" --surface "$arch_surface" enter >/dev/null 2>&1 || true
        else
            echo "ensure_session: failed to create architect surface: $arch_raw" >&2
        fi
    fi

    echo "$title"
}

# Ensure a per-task cmux workspace exists. Returns the *structured* portion
# of the title (e.g. `craft-llm-classification-task-015`) — callers use this
# as the lookup token. The actual title on the workspace may have a
# human-readable suffix appended (` · <human_title>`) for sidebar readability;
# _mux_ws_ref's prefix-matching keeps the lookup working either way.
#
# Args: <project_name> <task_id> [task_dir] [human_title]
ensure_task_session() {
    local project_name="$1" task_id="$2" task_dir="${3:-}" human_title="${4:-}"
    local structured="${CMUX_PREFIX}-${project_name}-${task_id}"
    local title="$structured"
    [[ -n "$human_title" ]] && title="${structured} · ${human_title}"

    local ws_ref
    ws_ref=$(_mux_ws_ref "$structured")
    if [[ -z "$ws_ref" ]]; then
        local raw
        raw=$(cmux new-workspace ${task_dir:+--cwd "$task_dir"} 2>&1)
        ws_ref=$(echo "$raw" | grep -oE 'workspace:[0-9]+' | head -1)
        if [[ -z "$ws_ref" ]]; then
            echo "ensure_task_session: failed to create cmux workspace: $raw" >&2
            return 1
        fi
        cmux rename-workspace --workspace "$ws_ref" "$title" >/dev/null 2>&1 || true
    else
        # Workspace already exists — refresh its title in case the human
        # title (from task frontmatter) has changed since creation.
        cmux rename-workspace --workspace "$ws_ref" "$title" >/dev/null 2>&1 || true
    fi

    # Co-locate the task workspace in the same cmux window as the project
    # workspace. `cmux new-workspace` has no --window flag and picks "current
    # window" based on GUI focus, so without this the task workspace can land
    # in a different window than the project — confusing for the operator.
    local project_title="${CMUX_PREFIX}-${project_name}"
    local task_win project_win
    task_win=$(_mux_ws_window "$structured")
    project_win=$(_mux_ws_window "$project_title")
    if [[ -n "$task_win" && -n "$project_win" && "$task_win" != "$project_win" ]]; then
        cmux move-workspace-to-window --workspace "$ws_ref" --window "$project_win" >/dev/null 2>&1 || true
    fi

    # Callers pass `$structured` to subsequent mux primitives (pane_is_running,
    # spawn_task_pane, kill_task_pane) — the prefix match in _mux_ws_ref
    # tolerates the human suffix on the actual workspace title.
    echo "$structured"
}

# Create a new surface for a task and run the agent in it.
#
# The surface's tab title is set to `$task_id` and that is now the canonical
# anchor for finding it later — `pane_is_running` / `kill_task_pane` walk
# the cmux tree looking for a surface with this title, no separate status
# entry needed. (Previous design wrote `craft:pane:<task-id>=<surface-ref>`
# to workspace status; that data is now in the tree itself via the tab
# title, and status was visually noisy in the sidebar.)
spawn_task_pane() {
    local session="$1" task_id="$2" prompt_file="$3" work_dir="$4"
    local agent="${5:-claude}"

    local ws_ref
    ws_ref=$(_mux_ws_ref "$session")
    [[ -n "$ws_ref" ]] || { echo "spawn_task_pane: no workspace titled '$session'" >&2; return 1; }

    local cmd
    cmd=$(provider_task_cmd "$agent" "$prompt_file" "$work_dir")

    # New cmux workspaces come with a single default terminal surface. Reuse
    # it if it's the only surface (fresh workspace). If there's already an
    # anchor surface tagged with this task_id, the task is being re-spawned —
    # the existing one stays; we create an additional surface so we don't
    # clobber an in-flight agent session.
    local surface_id
    local anchor
    anchor=$(_mux_surface_by_tab_title "$ws_ref" "$task_id")
    if [[ -z "$anchor" ]]; then
        local existing
        existing=$(cmux list-pane-surfaces --workspace "$ws_ref" 2>/dev/null \
            | grep -oE 'surface:[0-9]+')
        if [[ $(echo "$existing" | wc -l) -eq 1 ]]; then
            surface_id="$existing"
        fi
    fi

    if [[ -z "$surface_id" ]]; then
        local raw
        raw=$(cmux new-split down --workspace "$ws_ref" 2>&1)
        surface_id=$(echo "$raw" | grep -oE 'surface:[0-9]+' | head -1)
        if [[ -z "$surface_id" ]]; then
            echo "spawn_task_pane: failed to create surface: $raw" >&2
            return 1
        fi
    fi

    cmux rename-tab --workspace "$ws_ref" --surface "$surface_id" "$task_id" >/dev/null 2>&1 || true
    cmux send --workspace "$ws_ref" --surface "$surface_id" "$cmd" >/dev/null 2>&1 || true
    cmux send-key --workspace "$ws_ref" --surface "$surface_id" enter >/dev/null 2>&1 || true

    echo "$surface_id"
}

# Find a surface in a workspace by its tab title. Single tree call.
_mux_surface_by_tab_title() {
    local ws_ref="$1" title="$2"
    cmux tree --workspace "$ws_ref" --json 2>/dev/null \
        | jq -r --arg t "$title" '
            .windows[].workspaces[].panes[].surfaces[]
            | select(.title == $t) | .ref
          ' 2>/dev/null \
        | head -1
}

# Check if a task pane is still running. Finds the agent surface by its
# tab title (== task_id, set by spawn_task_pane), then checks whether
# it still appears in the workspace tree.
pane_is_running() {
    local session="$1" task_id="$2"
    local ws_ref
    ws_ref=$(_mux_ws_ref "$session")
    [[ -n "$ws_ref" ]] || return 1

    local surface_id
    surface_id=$(_mux_surface_by_tab_title "$ws_ref" "$task_id")
    [[ -n "$surface_id" ]] || return 1
    return 0
}

# Kill a task pane (real close API; no more "send exit" hack).
kill_task_pane() {
    local session="$1" task_id="$2"
    local ws_ref
    ws_ref=$(_mux_ws_ref "$session")
    [[ -n "$ws_ref" ]] || return 0

    local surface_id
    surface_id=$(_mux_surface_by_tab_title "$ws_ref" "$task_id")
    if [[ -n "$surface_id" ]]; then
        cmux close-surface --workspace "$ws_ref" --surface "$surface_id" >/dev/null 2>&1 || true
    fi
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

# --- Generic primitives for skills (not used by the orchestrator daemon) ---
#
# cmux surfaces don't have built-in stable names. We use cmux's own
# workspace-level status store (set-status / list-status / clear-status) as
# the name → surface-ref map. cmux is the single source of truth — no local
# state files. Lost only when the workspace itself is closed, at which point
# the surfaces are gone anyway.
#
# Status keys are namespaced as: craft:pane:<name>=<surface-ref>

_mux_status_key() {
    echo "craft:pane:$1"
}

_mux_lookup_ref() {
    # Given a pane name in a workspace (by title), print the surface ref or empty.
    local session="$1" name="$2"
    local ws_ref
    ws_ref=$(_mux_ws_ref "$session")
    [[ -n "$ws_ref" ]] || return 1
    local key
    key=$(_mux_status_key "$name")
    cmux list-status --workspace "$ws_ref" 2>/dev/null \
        | awk -F '=' -v k="$key" '$1==k {print $2; exit}'
}

_mux_surface_alive() {
    # Returns 0 if <surface-ref> still appears anywhere in the workspace tree.
    local session="$1" sid="$2"
    local ws_ref
    ws_ref=$(_mux_ws_ref "$session")
    [[ -n "$ws_ref" ]] || return 1
    cmux tree --workspace "$ws_ref" 2>/dev/null | grep -qE "\b${sid}\b"
}

mux_spawn_named_pane() {
    local session="$1" name="$2" cwd="$3" cmd="$4"

    local ws_ref
    ws_ref=$(_mux_ws_ref "$session")
    [[ -n "$ws_ref" ]] || { echo "mux-cmux: no workspace titled '$session'" >&2; return 1; }

    # Idempotent: if name is recorded and the surface is still alive, no-op.
    local existing
    existing=$(_mux_lookup_ref "$session" "$name")
    if [[ -n "$existing" ]] && _mux_surface_alive "$session" "$existing"; then
        return 0
    fi

    # Create a new surface in the target workspace. new-split prints
    # "OK surface:N workspace:M" — grep the surface ref out.
    local sid
    sid=$(cmux new-split down --workspace "$ws_ref" 2>/dev/null \
        | grep -oE 'surface:[0-9]+' \
        | head -1)

    if [[ -z "$sid" ]]; then
        echo "mux-cmux: failed to create new surface in $session" >&2
        return 1
    fi

    # Run the command in the new surface.
    cmux send --workspace "$ws_ref" --surface "$sid" "cd '$cwd' && $cmd" >/dev/null 2>&1 || true
    cmux send-key --workspace "$ws_ref" --surface "$sid" enter >/dev/null 2>&1 || true

    # Tag the surface with our name (cosmetic — visible to the operator) and
    # record the authoritative name→ref map in workspace status.
    cmux rename-tab --workspace "$ws_ref" --surface "$sid" "$name" >/dev/null 2>&1 || true
    cmux set-status "$(_mux_status_key "$name")" "$sid" --workspace "$ws_ref" >/dev/null 2>&1 || true
}

mux_send_to_pane() {
    local session="$1" name="$2" text="$3"
    local ws_ref
    ws_ref=$(_mux_ws_ref "$session")
    [[ -n "$ws_ref" ]] || { echo "mux-cmux: no workspace titled '$session'" >&2; return 1; }
    local sid
    sid=$(_mux_lookup_ref "$session" "$name")
    [[ -n "$sid" ]] || { echo "mux-cmux: no pane named '$name' in '$session'" >&2; return 1; }
    cmux send --workspace "$ws_ref" --surface "$sid" "$text" >/dev/null 2>&1 || true
    cmux send-key --workspace "$ws_ref" --surface "$sid" enter >/dev/null 2>&1 || true
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
    if [[ -n "$sid" ]]; then
        cmux close-surface --workspace "$ws_ref" --surface "$sid" >/dev/null 2>&1 || true
    fi
    cmux clear-status "$(_mux_status_key "$name")" --workspace "$ws_ref" >/dev/null 2>&1 || true
}
