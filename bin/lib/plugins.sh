#!/usr/bin/env bash
# plugins.sh — Shared plugin discovery, asset sync, and extension metadata.

if [[ -z "${CRAFT_ROOT:-}" ]]; then
    _PLUGINS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CRAFT_ROOT="$(cd "$_PLUGINS_LIB_DIR/../.." && pwd)"
fi

BASE_QUEUE_STATES=(drafts pending approved in-progress waiting done blocked archive)

plugin_enabled_plugins() {
    local project_dir="$1"
    local config_file="$project_dir/craft.conf"

    if [[ -f "$config_file" ]]; then
        (
            # shellcheck source=/dev/null
            source "$config_file"
            printf '%s\n' "${PLUGINS:-}"
        )
    fi | tr ',' '\n' | while IFS= read -r plugin; do
        plugin="$(echo "$plugin" | xargs)"
        [[ -n "$plugin" ]] && printf '%s\n' "$plugin"
    done
}

_plugin_conf_value() {
    local plugin_dir="$1" var_name="$2"
    local conf="$plugin_dir/plugin.conf"
    [[ -f "$conf" ]] || return 0
    (
        # shellcheck source=/dev/null
        unset "$var_name"
        source "$conf"
        printf '%s' "${!var_name:-}"
    )
}

plugin_dependencies() {
    local plugin="$1" plugin_dir deps dep
    plugin_dir="$CRAFT_ROOT/plugins/$plugin"
    [[ -d "$plugin_dir" ]] || return 0
    deps="$(_plugin_conf_value "$plugin_dir" DEPENDS_ON)"
    [[ -n "$deps" ]] || return 0
    printf '%s\n' "$deps" | tr ',' '\n' | while IFS= read -r dep; do
        dep="$(echo "$dep" | xargs)"
        [[ -n "$dep" ]] && printf '%s\n' "$dep"
    done
}

plugin_is_enabled() {
    local project_dir="$1" wanted="$2" plugin
    while IFS= read -r plugin; do
        [[ "$plugin" == "$wanted" ]] && return 0
    done < <(plugin_enabled_plugins "$project_dir")
    return 1
}

plugin_missing_dependencies() {
    local project_dir="$1" plugin="$2" dep
    while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        if [[ ! -d "$CRAFT_ROOT/plugins/$dep" ]]; then
            printf '%s\n' "$dep"
        elif ! plugin_is_enabled "$project_dir" "$dep"; then
            printf '%s\n' "$dep"
        fi
    done < <(plugin_dependencies "$plugin")
}

plugin_validate_dependencies() {
    local project_dir="$1" plugin missing failed=0
    while IFS= read -r plugin; do
        [[ -n "$plugin" ]] || continue
        missing="$(plugin_missing_dependencies "$project_dir" "$plugin" | paste -sd, -)"
        if [[ -n "$missing" ]]; then
            echo "[plugins] $plugin: missing DEPENDS_ON plugin(s): $missing" >&2
            failed=1
        fi
    done < <(plugin_enabled_plugins "$project_dir")
    [[ $failed -eq 0 ]]
}

_plugin_valid_queue_state() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

_plugin_valid_skill_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

plugin_queue_states() {
    local project_dir="$1"
    local seen=" "
    local state

    for state in "${BASE_QUEUE_STATES[@]}"; do
        printf '%s\n' "$state"
        seen="${seen}${state} "
    done

    local plugin plugin_dir states raw_state
    while IFS= read -r plugin; do
        plugin_dir="$CRAFT_ROOT/plugins/$plugin"
        [[ -d "$plugin_dir" ]] || continue
        states="$(_plugin_conf_value "$plugin_dir" QUEUE_STATES)"
        [[ -n "$states" ]] || continue
        while IFS= read -r raw_state; do
            state="$(echo "$raw_state" | xargs)"
            [[ -n "$state" ]] || continue
            if ! _plugin_valid_queue_state "$state"; then
                echo "[plugins] Warning: plugin '$plugin' ignored invalid QUEUE_STATES entry '$state'" >&2
                continue
            fi
            if [[ "$seen" != *" $state "* ]]; then
                printf '%s\n' "$state"
                seen="${seen}${state} "
            fi
        done < <(printf '%s\n' "$states" | tr ',' '\n')
    done < <(plugin_enabled_plugins "$project_dir")
}

_plugin_sync_one_asset() {
    local plugin_name="$1" src="$2" dst="$3" plugin_project="$4"

    mkdir -p "$(dirname "$dst")"

    if [[ -L "$dst" ]]; then
        local current
        current="$(readlink "$dst")"
        if [[ "$current" == "$src" ]]; then
            return 0
        fi
        if [[ "$current" == "$plugin_project/"* ]]; then
            rm -f "$dst"
        else
            echo "[plugins] $plugin_name: refusing to replace symlink $dst -> $current" >&2
            return 1
        fi
    elif [[ -e "$dst" ]]; then
        echo "[plugins] $plugin_name: refusing to replace existing project file $dst" >&2
        return 1
    fi

    ln -s "$src" "$dst"
}

plugin_sync_project_assets() {
    local project_dir="$1"
    local plugin_name_filter="${2:-}"
    local failed=0
    local plugin plugin_dir plugin_project

    if [[ -n "$plugin_name_filter" ]]; then
        local missing
        missing="$(plugin_missing_dependencies "$project_dir" "$plugin_name_filter" | paste -sd, -)"
        if [[ -n "$missing" ]]; then
            echo "[plugins] $plugin_name_filter: missing DEPENDS_ON plugin(s): $missing" >&2
            return 1
        fi
    elif ! plugin_validate_dependencies "$project_dir"; then
        return 1
    fi

    while IFS= read -r plugin; do
        [[ -z "$plugin_name_filter" || "$plugin" == "$plugin_name_filter" ]] || continue
        plugin_dir="$CRAFT_ROOT/plugins/$plugin"
        plugin_project="$plugin_dir/project"
        [[ -d "$plugin_project" ]] || continue

        while IFS= read -r -d '' src; do
            local rel dst
            rel="${src#"$plugin_project/"}"
            dst="$project_dir/$rel"
            if ! _plugin_sync_one_asset "$plugin" "$src" "$dst" "$plugin_project"; then
                failed=1
            fi
        done < <(
            find "$plugin_project" \
                \( -path "$plugin_project/.claude/skills/*" -o -path "$plugin_project/.codex/skills/*" \) -prune -o \
                \( -type f -o -type l \) -print0
        )
    done < <(plugin_enabled_plugins "$project_dir")

    if ! plugin_sync_skills "$project_dir" "$plugin_name_filter"; then
        failed=1
    fi

    [[ $failed -eq 0 ]]
}

plugin_sync_skills() {
    if [[ ${BASH_VERSINFO[0]:-0} -lt 4 ]]; then
        echo "[plugins] plugin_sync_skills requires bash 4+ (you have ${BASH_VERSION:-unknown}). On macOS: 'brew install bash'." >&2
        return 1
    fi
    local project_dir="$1"
    local plugin_name_filter="${2:-}"
    local failed=0
    local plugin plugin_dir skills_dir skill_src skill_name
    local -A providers=()

    while IFS= read -r plugin; do
        plugin_dir="$CRAFT_ROOT/plugins/$plugin"
        skills_dir="$plugin_dir/skills"
        [[ -d "$skills_dir" ]] || continue
        while IFS= read -r -d '' skill_src; do
            skill_name="$(basename "$skill_src")"
            if ! _plugin_valid_skill_name "$skill_name"; then
                echo "[plugins] $plugin: invalid skill name '$skill_name'" >&2
                failed=1
                continue
            fi
            if [[ ! -f "$skill_src/SKILL.md" ]]; then
                echo "[plugins] $plugin: skill '$skill_name' is missing SKILL.md" >&2
                failed=1
                continue
            fi
            if [[ -n "${providers[$skill_name]:-}" ]]; then
                echo "[plugins] duplicate skill provider '$skill_name': ${providers[$skill_name]} and $plugin" >&2
                failed=1
                continue
            fi
            providers[$skill_name]="$plugin"
        done < <(find "$skills_dir" -mindepth 1 -maxdepth 1 -type d -print0)
    done < <(plugin_enabled_plugins "$project_dir")

    [[ $failed -eq 0 ]] || return 1

    while IFS= read -r plugin; do
        [[ -z "$plugin_name_filter" || "$plugin" == "$plugin_name_filter" ]] || continue
        plugin_dir="$CRAFT_ROOT/plugins/$plugin"
        skills_dir="$plugin_dir/skills"
        [[ -d "$skills_dir" ]] || continue
        while IFS= read -r -d '' skill_src; do
            skill_name="$(basename "$skill_src")"
            if ! _plugin_sync_one_asset "$plugin" "$skill_src" "$project_dir/.claude/skills/$skill_name" "$plugin_dir/project"; then
                failed=1
            fi
            if ! _plugin_sync_one_asset "$plugin" "$skill_src" "$project_dir/.codex/skills/$skill_name" "$plugin_dir/project"; then
                failed=1
            fi
        done < <(find "$skills_dir" -mindepth 1 -maxdepth 1 -type d -print0)
    done < <(plugin_enabled_plugins "$project_dir")

    [[ $failed -eq 0 ]]
}
