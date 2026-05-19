# orchestrator-skills/hooks.sh — Lifecycle hooks for the orchestrator-skills plugin
#
# Project skills and commands are exposed through this plugin's project/ tree.
# Craft core syncs those assets into each enabled project as symlinks.

# Resolve this plugin's directory.
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Dependency check ---
check_deps() {
    return 0
}

# --- Hooks ---

# Called once by `craft plugin add` after the plugin is symlinked into the
# project. Interactively offers to set DEFAULT_AGENT=codex (this plugin's
# coding-agent assumption — the work-task flow is designed around Codex doing
# the coding and a Claude sub-agent doing cross-model review). Idempotent;
# respects user choice if they decline or set something else.
on_install() {
    local project_dir="${1:-$PROJECT_DIR}"
    local conf="$project_dir/craft.conf"
    [[ -f "$conf" ]] || { echo "[orchestrator-skills] on_install: no craft.conf at $conf" >&2; return 1; }

    local current=""
    if grep -qE '^[[:space:]]*DEFAULT_AGENT=' "$conf"; then
        current="$(grep -E '^[[:space:]]*DEFAULT_AGENT=' "$conf" | head -1 \
            | sed -E 's/^[[:space:]]*DEFAULT_AGENT=//; s/^"//; s/"$//')"
    fi

    if [[ "$current" == "codex" ]]; then
        echo "[orchestrator-skills] DEFAULT_AGENT=codex already set"
    else
        # `claude` is craft's template default — treat it as "default, not a
        # deliberate user choice" so we offer the change with default Y. Anything
        # else is a real user-set value and we default to leaving it alone.
        local prompt default
        if [[ -z "$current" ]] || [[ "$current" == "claude" ]]; then
            if [[ -z "$current" ]]; then
                prompt="Set DEFAULT_AGENT=codex so the orchestrator launches Codex as the coding agent? [Y/n]"
            else
                prompt="Change DEFAULT_AGENT from 'claude' (default) to 'codex' for the coding agent? [Y/n]"
            fi
            default="y"
        else
            prompt="Change DEFAULT_AGENT from '$current' to 'codex'? [y/N]"
            default="n"
        fi

        local answer
        if [[ -t 0 ]]; then
            read -rp "[orchestrator-skills] $prompt " answer
            answer="${answer:-$default}"
        else
            answer="$default"
            echo "[orchestrator-skills] (non-interactive) defaulting to '$default': $prompt"
        fi

        case "${answer,,}" in
            y|yes)
                if [[ -n "$current" ]]; then
                    if sed --version 2>/dev/null | grep -q GNU; then
                        sed -i -E "s|^[[:space:]]*DEFAULT_AGENT=.*$|DEFAULT_AGENT=codex|" "$conf"
                    else
                        sed -i "" -E "s|^[[:space:]]*DEFAULT_AGENT=.*$|DEFAULT_AGENT=codex|" "$conf"
                    fi
                    echo "[orchestrator-skills] updated DEFAULT_AGENT=codex (was '$current')"
                else
                    printf '\n# Added by orchestrator-skills/on_install\nDEFAULT_AGENT=codex\n' >> "$conf"
                    echo "[orchestrator-skills] appended DEFAULT_AGENT=codex to craft.conf"
                fi
                ;;
            *)
                if [[ -n "$current" ]]; then
                    echo "[orchestrator-skills] keeping DEFAULT_AGENT=$current"
                else
                    echo "[orchestrator-skills] leaving DEFAULT_AGENT unset — the orchestrator will use 'claude' per the template default"
                    echo "[orchestrator-skills] note: this plugin's work-task flow is designed assuming Codex is the coding agent"
                fi
                ;;
        esac
    fi

    if ! grep -qE '^[[:space:]]*DASHBOARD_CMD=' "$conf"; then
        cat >> "$conf" <<'EOF'

# Added by orchestrator-skills/on_install
DASHBOARD_CMD='cd "$CRAFT_ROOT/plugins/orchestrator-skills/dashboard" && bun server.tsx --project "$PROJECT_DIR" --port "$CRAFT_DASHBOARD_PORT"'
EOF
        echo "[orchestrator-skills] appended DASHBOARD_CMD for the web dashboard"
    fi
}

# Called on every orchestrator poll. Project asset syncing is handled by Craft
# core before this hook runs.
on_poll() {
    return 0
}

# Called once when a task starts (moves to in-progress). Currently a no-op; the
# project-scope install at on_poll covers both architect and task agents.
# Reserved for future per-task skill scoping if we want it.
on_started() {
    return 0
}
