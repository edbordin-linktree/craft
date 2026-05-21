#!/usr/bin/env bash
# providers.sh — Agent provider abstraction for model-agnostic task execution
#
# Each provider maps to a CLI tool that can accept a prompt and run interactively.
# Add new providers by extending the case statements below.

# Build provider-specific CLI flags from config variables.
# Looks for <PROVIDER>_APPROVAL_MODE (e.g. CODEX_APPROVAL_MODE=bypass).
# Usage: provider_flags <provider>
provider_flags() {
    local provider="$1"
    local upper
    upper=$(echo "$provider" | tr '[:lower:]' '[:upper:]')

    local approval_var="${upper}_APPROVAL_MODE"
    local approval="${!approval_var:-}"

    case "$provider" in
        codex)
            # bypass:    no approvals, no sandbox (--dangerously-bypass-approvals-and-sandbox)
            # never:     no approvals, sandboxed (-a never)
            # full-auto: model decides when to ask, sandboxed (--full-auto)
            # auto-edit, on-request, untrusted: passed through to -a
            if [[ "$approval" == "bypass" ]]; then
                echo "--dangerously-bypass-approvals-and-sandbox"
            elif [[ "$approval" == "full-auto" ]]; then
                echo "--full-auto"
            elif [[ -n "$approval" ]]; then
                echo "-a $approval"
            fi
            ;;
        claude)
            if [[ "$approval" == "bypass" || "$approval" == "full-auto" ]]; then
                echo "--dangerously-skip-permissions"
            fi
            ;;
    esac
}

# Build the env-setup snippet for an agent spawn. Cmux/tmux surfaces start a
# fresh shell that does NOT inherit the orchestrator process's env directly, so
# CRAFT_ROOT and the craft/plugin script dirs need to be re-injected. This
# makes `craft-mux` and enabled plugin helper scripts usable from inside the
# spawned agent without depending on the operator's shell init.
#
# Always emits a syntactically-valid shell expression — falls back to `:`
# (the no-op builtin) when CRAFT_ROOT is unset, so the surrounding
# `cd … && ${env} && cmd` template never collapses to `… && && cmd`.
_provider_env_setup() {
    local craft_root="${CRAFT_ROOT:-}"
    if [[ -z "$craft_root" ]]; then
        printf ':'
        return
    fi
    local scripts_path="" dir
    for dir in "$craft_root"/plugins/*/scripts; do
        [[ -d "$dir" ]] || continue
        scripts_path="${scripts_path:+$scripts_path:}$dir"
    done
    printf "export CRAFT_ROOT='%s' && export PATH='%s/bin%s%s:'\$PATH" \
        "$craft_root" "$craft_root" "${scripts_path:+:}" "$scripts_path"
}

# Build the tmux command to launch an agent for a task
# Usage: provider_task_cmd <provider> <prompt_file> <work_dir>
provider_task_cmd() {
    local provider="$1" prompt_file="$2" work_dir="$3"

    local flags env
    flags=$(provider_flags "$provider")
    env=$(_provider_env_setup)

    case "$provider" in
        claude)
            echo "cd '${work_dir}' && ${env} && claude${flags:+ $flags} \"\$(cat '${prompt_file}')\" ; rm -f '${prompt_file}'"
            ;;
        codex)
            echo "cd '${work_dir}' && ${env} && codex${flags:+ $flags} \"\$(cat '${prompt_file}')\" ; rm -f '${prompt_file}'"
            ;;
        *)
            # Generic fallback: assume CLI takes prompt as first positional arg
            echo "cd '${work_dir}' && ${env} && ${provider}${flags:+ $flags} \"\$(cat '${prompt_file}')\" ; rm -f '${prompt_file}'"
            ;;
    esac
}

# Build the tmux command to launch an architect session
# Usage: provider_architect_cmd <provider> <skill_file> <work_dir>
provider_architect_cmd() {
    local provider="$1" skill_file="$2" work_dir="$3"

    local flags env
    flags=$(provider_flags "$provider")
    env=$(_provider_env_setup)

    case "$provider" in
        claude)
            echo "cd '${work_dir}' && ${env} && claude${flags:+ $flags} \"\$(cat '${skill_file}')\" ; exec \$SHELL"
            ;;
        codex)
            echo "cd '${work_dir}' && ${env} && codex${flags:+ $flags} \"\$(cat '${skill_file}')\" ; exec \$SHELL"
            ;;
        *)
            echo "cd '${work_dir}' && ${env} && ${provider}${flags:+ $flags} \"\$(cat '${skill_file}')\" ; exec \$SHELL"
            ;;
    esac
}

# Load project-level provider config
# Usage: load_provider_config <project_dir>
# Sets: DEFAULT_AGENT, ARCHITECT_AGENT, MULTIPLEXER
load_provider_config() {
    local project_dir="$1"
    local config_file="$project_dir/craft.conf"

    # Defaults
    DEFAULT_AGENT="${DEFAULT_AGENT:-claude}"
    ARCHITECT_AGENT="${ARCHITECT_AGENT:-claude}"
    MULTIPLEXER="${MULTIPLEXER:-tmux}"

    if [[ -f "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file"
    fi

    # Resolve operator name: config > git > $USER
    OPERATOR_NAME="${OPERATOR_NAME:-$(git config user.name 2>/dev/null || echo "${USER:-operator}")}"
    export OPERATOR_NAME MULTIPLEXER
}

# Get the agent provider for a specific task (task-level override or project default)
# Usage: task_agent <task_file>
task_agent() {
    local file="$1"
    local agent
    agent=$(task_field "$file" "agent")
    echo "${agent:-$DEFAULT_AGENT}"
}
