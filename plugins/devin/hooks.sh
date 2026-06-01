# devin — Event-driven Devin session settlement.

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

check_deps() {
    command -v curl >/dev/null || { echo "curl is required"; return 1; }
    command -v jq >/dev/null || { echo "jq is required"; return 1; }
}

on_poll() {
    [[ -n "${PROJECT_DIR:-}" ]] || return 0
    [[ -n "${DEVIN_API_KEY:-}" ]] || return 0
    "$PLUGIN_DIR/scripts/poll-devin-sessions" --project-dir "$PROJECT_DIR" >/dev/null 2>&1 || true
}
