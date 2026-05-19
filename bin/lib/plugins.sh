#!/usr/bin/env bash
# plugins.sh — Shared plugin discovery, asset sync, and extension metadata.

if [[ -z "${CRAFT_ROOT:-}" ]]; then
    _PLUGINS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CRAFT_ROOT="$(cd "$_PLUGINS_LIB_DIR/../.." && pwd)"
fi

BASE_QUEUE_STATES=(pending approved in-progress waiting done blocked archive)

_plugin_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

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
        plugin="$(_plugin_trim "$plugin")"
        [[ -n "$plugin" ]] && printf '%s\n' "$plugin"
    done
}

_plugin_conf_value() {
    local plugin_dir="$1" var_name="$2"
    local conf="$plugin_dir/plugin.conf"
    [[ -f "$conf" ]] || return 0
    (
        # shellcheck source=/dev/null
        source "$conf"
        printf '%s' "${!var_name:-}"
    )
}

_plugin_valid_queue_state() {
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
            state="$(_plugin_trim "$raw_state")"
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

plugin_queue_states_array() {
    local project_dir="$1"
    mapfile -t QUEUE_STATES < <(plugin_queue_states "$project_dir")
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
        done < <(find "$plugin_project" \( -type f -o -type l \) -print0)
    done < <(plugin_enabled_plugins "$project_dir")

    [[ $failed -eq 0 ]]
}
