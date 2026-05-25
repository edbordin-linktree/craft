# craft-dashboard — Web dashboard and cmux task badge integration.

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/hook-runtime.sh
source "${CRAFT_ROOT:-$(cd "$PLUGIN_DIR/../.." && pwd -P)}/bin/lib/hook-runtime.sh"

on_install() {
    local project_dir="${1:-$PROJECT_DIR}"
    local conf="$project_dir/craft.conf"
    [[ -f "$conf" ]] || { echo "[craft-dashboard] on_install: no craft.conf at $conf" >&2; return 1; }
    if ! grep -qE '^[[:space:]]*DASHBOARD_CMD=' "$conf"; then
        cat >> "$conf" <<'EOF'

# Added by craft-dashboard/on_install
DASHBOARD_CMD='cd "$CRAFT_ROOT/plugins/craft-dashboard/dashboard" && bun server.tsx --project "$PROJECT_DIR" --port "$CRAFT_DASHBOARD_PORT"'
EOF
        echo "[craft-dashboard] appended DASHBOARD_CMD for the web dashboard"
    fi
}

on_task_state_after() {
    craft_hook_parse_task_state_args "$@"
    [[ -n "$TASK_ID" && -n "$STATUS" ]] || return 0
    "$PLUGIN_DIR/scripts/set-task-state" "$TASK_ID" "$STATUS" >/dev/null 2>&1 || true
}
