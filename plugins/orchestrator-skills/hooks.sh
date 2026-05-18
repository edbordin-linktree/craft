# orchestrator-skills/hooks.sh — Lifecycle hooks for the orchestrator-skills plugin
#
# Installs the canonical skill set into the project's .claude/ AND .codex/
# directories (so the discovery works for whichever CLI ends up driving the
# agent — Claude Code or Codex). Idempotent; safe to run on every poll.

# Resolve this plugin's directory.
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load plugin.conf
if [[ -f "$PLUGIN_DIR/plugin.conf" ]]; then
    # shellcheck source=/dev/null
    source "$PLUGIN_DIR/plugin.conf"
fi
INSTALL_MODE="${INSTALL_MODE:-symlink}"

# Agent-config dirs in the project. $PROJECT_DIR is set by run-hook.sh.
# Skills go into both. Slash commands stay in .claude/commands/ only (Claude
# Code feature; codex has no equivalent).
CLAUDE_DIR="$PROJECT_DIR/.claude"
CODEX_DIR="$PROJECT_DIR/.codex"

# --- Dependency check ---
check_deps() {
    return 0
}

# --- Helpers ---

_install_one() {
    # Install one source path into one absolute destination path.
    #   $1 — absolute source path
    #   $2 — absolute destination path
    local src="$1"
    local dst="$2"

    [[ -e "$src" ]] || {
        echo "[orchestrator-skills] missing source: $src" >&2
        return 1
    }

    mkdir -p "$(dirname "$dst")"

    if [[ "$INSTALL_MODE" == "symlink" ]]; then
        if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$src" ]]; then
            return 0
        fi
        if [[ -e "$dst" ]] || [[ -L "$dst" ]]; then
            rm -rf "$dst"
        fi
        ln -s "$src" "$dst"
    else
        if [[ -d "$src" ]]; then
            mkdir -p "$dst"
            if command -v rsync >/dev/null; then
                rsync -a --delete "$src/" "$dst/"
            else
                rm -rf "$dst"
                cp -R "$src" "$dst"
            fi
        else
            cp "$src" "$dst"
        fi
    fi
}

_install_skill() {
    # Install a skill into BOTH .claude/skills/ and .codex/skills/.
    #   $1 — path under plugin (e.g. skills/babysit-pr)
    #   $2 — destination path under each agent-config dir (e.g. skills/babysit-pr)
    local src="$PLUGIN_DIR/$1"
    _install_one "$src" "$CLAUDE_DIR/$2"
    _install_one "$src" "$CODEX_DIR/$2"
}

_install_command() {
    # Install a slash command into .claude/commands/ only.
    local src="$PLUGIN_DIR/$1"
    _install_one "$src" "$CLAUDE_DIR/$2"
}

_install_all() {
    # Skills — installed into both .claude/skills/ and .codex/skills/.
    _install_skill "skills/delegate-to-devin"    "skills/delegate-to-devin"
    _install_skill "skills/babysit-pr"           "skills/babysit-pr"      # includes references/
    _install_skill "skills/review-pr"            "skills/review-pr"       # includes references/ + agents/
    _install_skill "skills/plan-reviewer"        "skills/plan-reviewer"   # includes references/ (used by architect)
    _install_skill "skills/architect-delegation" "skills/architect-delegation"
    _install_skill "skills/cmux"                 "skills/cmux"
    # delegate-to-claude, delegate-to-codex, multiagent-task, ma-task —
    # archived under plugins/orchestrator-skills/archive/, NOT installed.
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
        return 0
    fi

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
}

# Called on every orchestrator poll. Cheap and idempotent — verifies the
# install state and re-syncs anything missing.
on_poll() {
    _install_all
}

# Called once when a task starts (moves to in-progress). Currently a no-op; the
# project-scope install at on_poll covers both architect and task agents.
# Reserved for future per-task skill scoping if we want it.
on_started() {
    return 0
}
