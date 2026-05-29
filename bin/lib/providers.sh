#!/usr/bin/env bash
# providers.sh — Agent provider abstraction for model-agnostic task execution
#
# Each provider maps to a CLI tool that can accept a prompt and run interactively.
# Add new providers by extending the case statements below.

# Build provider-specific CLI flags from config variables.
# Looks for <PROVIDER>_APPROVAL_MODE (e.g. CODEX_APPROVAL_MODE=bypass).
# Usage: provider_flags <provider>
provider_flags() {
    local provider="$1" model_override="${2:-}"
    local upper
    upper=$(echo "$provider" | tr '[:lower:]' '[:upper:]' | sed -E 's/[^A-Z0-9_]/_/g')

    local approval_var="${upper}_APPROVAL_MODE"
    local approval="${!approval_var:-}"
    local model_var="${upper}_MODEL"
    local model="${model_override:-${!model_var:-}}"
    local flags=""

    case "$provider" in
        codex)
            # bypass:    no approvals, no sandbox (--dangerously-bypass-approvals-and-sandbox)
            # never:     no approvals, sandboxed (-a never)
            # full-auto: model decides when to ask, sandboxed (--full-auto)
            # auto-edit, on-request, untrusted: passed through to -a
            if [[ "$approval" == "bypass" ]]; then
                flags="--dangerously-bypass-approvals-and-sandbox"
            elif [[ "$approval" == "full-auto" ]]; then
                flags="--full-auto"
            elif [[ -n "$approval" ]]; then
                flags="-a $approval"
            fi
            [[ -n "$model" ]] && flags="${flags:+$flags }--model $(printf '%q' "$model")"
            echo "$flags"
            ;;
        claude)
            if [[ "$approval" == "bypass" || "$approval" == "full-auto" ]]; then
                flags="--dangerously-skip-permissions"
            fi
            [[ -n "$model" ]] && flags="${flags:+$flags }--model $(printf '%q' "$model")"
            echo "$flags"
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
    local provider="$1" prompt_file="$2" work_dir="$3" model="${4:-}"

    local flags env
    flags=$(provider_flags "$provider" "$model")
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

# Build the command to resume an existing agent conversation for a task.
# The prompt is intentionally a short resume instruction owned by the caller;
# this function only maps the abstract operation onto each agent CLI.
# Usage: provider_task_resume_cmd <provider> <prompt_file> <work_dir> [model]
provider_task_resume_cmd() {
    local provider="$1" prompt_file="$2" work_dir="$3" model="${4:-}"

    local flags env
    flags=$(provider_flags "$provider" "$model")
    env=$(_provider_env_setup)

    case "$provider" in
        claude)
            echo "cd '${work_dir}' && ${env} && claude --continue${flags:+ $flags} \"\$(cat '${prompt_file}')\" ; rm -f '${prompt_file}'"
            ;;
        codex)
            echo "cd '${work_dir}' && ${env} && codex${flags:+ $flags} resume --last \"\$(cat '${prompt_file}')\" ; rm -f '${prompt_file}'"
            ;;
        *)
            # Generic providers do not have a known resume primitive; use the
            # normal task launch contract so the caller still gets a pane.
            provider_task_cmd "$provider" "$prompt_file" "$work_dir" "$model"
            ;;
    esac
}

# Build the tmux command to launch an architect session
# Usage: provider_architect_cmd <provider> <skill_file> <work_dir>
provider_architect_cmd() {
    local provider="$1" skill_file="$2" work_dir="$3" model="${4:-${ARCHITECT_AGENT_MODEL:-}}"

    local flags env
    flags=$(provider_flags "$provider" "$model")
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
    local file="$1" project_dir="${2:-}"
    local agent workflow_agent
    agent=$(task_field "$file" "agent")
    if [[ -z "$agent" && -n "$project_dir" ]] && declare -f workflow_default_agent >/dev/null 2>&1; then
        workflow_agent="$(workflow_default_agent "$project_dir" "$file" 2>/dev/null || true)"
        agent="$workflow_agent"
    fi
    echo "${agent:-$DEFAULT_AGENT}"
}

task_agent_model() {
    local file="$1" project_dir="${2:-}"
    local model workflow_model
    model="$(task_field "$file" "agent_model")"
    if [[ -z "$model" && -n "$project_dir" ]] && declare -f workflow_default_agent_model >/dev/null 2>&1; then
        workflow_model="$(workflow_default_agent_model "$project_dir" "$file" 2>/dev/null || true)"
        model="$workflow_model"
    fi
    echo "$model"
}
