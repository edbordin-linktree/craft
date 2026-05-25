# codex-agent — prefer Codex for task execution.

on_install() {
    local project_dir="${1:-$PROJECT_DIR}"
    local conf="$project_dir/craft.conf"
    [[ -f "$conf" ]] || { echo "[codex-agent] on_install: no craft.conf at $conf" >&2; return 1; }

    local current=""
    if grep -qE '^[[:space:]]*DEFAULT_AGENT=' "$conf"; then
        current="$(grep -E '^[[:space:]]*DEFAULT_AGENT=' "$conf" | head -1 \
            | sed -E 's/^[[:space:]]*DEFAULT_AGENT=//; s/^"//; s/"$//')"
    fi

    if [[ "$current" == "codex" ]]; then
        echo "[codex-agent] DEFAULT_AGENT=codex already set"
        return 0
    fi

    local prompt default answer
    if [[ -z "$current" || "$current" == "claude" ]]; then
        prompt="Set DEFAULT_AGENT=codex so the orchestrator launches Codex as the coding agent? [Y/n]"
        default="y"
    else
        prompt="Change DEFAULT_AGENT from '$current' to 'codex'? [y/N]"
        default="n"
    fi

    if [[ -t 0 ]]; then
        read -rp "[codex-agent] $prompt " answer
        answer="${answer:-$default}"
    else
        answer="$default"
        echo "[codex-agent] (non-interactive) defaulting to '$default': $prompt"
    fi

    case "${answer,,}" in
        y|yes)
            if [[ -n "$current" ]]; then
                if sed --version 2>/dev/null | grep -q GNU; then
                    sed -i -E "s|^[[:space:]]*DEFAULT_AGENT=.*$|DEFAULT_AGENT=codex|" "$conf"
                else
                    sed -i "" -E "s|^[[:space:]]*DEFAULT_AGENT=.*$|DEFAULT_AGENT=codex|" "$conf"
                fi
                echo "[codex-agent] updated DEFAULT_AGENT=codex (was '$current')"
            else
                printf '\n# Added by codex-agent/on_install\nDEFAULT_AGENT=codex\n' >> "$conf"
                echo "[codex-agent] appended DEFAULT_AGENT=codex to craft.conf"
            fi
            ;;
        *)
            [[ -n "$current" ]] && echo "[codex-agent] keeping DEFAULT_AGENT=$current"
            ;;
    esac
}
