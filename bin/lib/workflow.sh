#!/usr/bin/env bash
# workflow.sh — Workflow stage resolution and prompt composition.

if [[ -z "${CRAFT_ROOT:-}" ]]; then
    _WORKFLOW_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CRAFT_ROOT="$(cd "$_WORKFLOW_LIB_DIR/../.." && pwd)"
fi

# shellcheck source=bin/lib/queue.sh
source "$CRAFT_ROOT/bin/lib/queue.sh"
# shellcheck source=bin/lib/plugins.sh
source "$CRAFT_ROOT/bin/lib/plugins.sh"

workflow_preset_dir() {
    local project_dir="" workflow provider="" file plugin plugin_file
    if [[ $# -eq 1 ]]; then
        workflow="$1"
    else
        project_dir="$1"
        workflow="$2"
    fi

    file="$CRAFT_ROOT/workflows/$workflow"
    if [[ -f "$file/workflow.conf" ]]; then
        provider="$file"
    fi

    if [[ -n "$project_dir" ]]; then
        while IFS= read -r plugin; do
            plugin_file="$CRAFT_ROOT/plugins/$plugin/workflows/$workflow"
            [[ -f "$plugin_file/workflow.conf" ]] || continue
            if [[ -n "$provider" ]]; then
                echo "duplicate_workflow_provider: $workflow" >&2
                return 2
            fi
            provider="$plugin_file"
        done < <(plugin_enabled_plugins "$project_dir")
    fi

    [[ -n "$provider" ]] || return 1
    echo "$provider"
}

workflow_task_workflow() {
    task_workflow "$1"
}

workflow_base_stages() {
    local project_dir="" workflow preset_dir conf stages
    if [[ $# -eq 1 ]]; then
        workflow="$1"
    else
        project_dir="$1"
        workflow="$2"
    fi
    [[ "$workflow" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "workflow_path_escape: $workflow" >&2; return 1; }
    preset_dir="$(workflow_preset_dir "$project_dir" "$workflow")" || { echo "workflow_not_found: $workflow" >&2; return 1; }
    preset_dir="$(cd "$preset_dir" 2>/dev/null && pwd -P)" || { echo "workflow_not_found: $workflow" >&2; return 1; }
    conf="$preset_dir/workflow.conf"
    [[ -f "$conf" ]] || { echo "workflow_not_found: $workflow" >&2; return 1; }
    stages="$(
        # shellcheck source=/dev/null
        unset STAGES
        source "$conf"
        printf '%s' "${STAGES:-}"
    )"
    [[ -n "$stages" ]] || { echo "workflow_has_no_stages: $workflow" >&2; return 1; }
    printf '%s\n' "$stages" | tr ',' ' ' | xargs -n1
}

workflow_task_options_json() {
    task_workflow_options_json "$1"
}

workflow_stage_file_frontmatter() {
    local file="$1" field="$2"
    [[ -f "$file" ]] || return 0
    awk -v field="$field" '
        NR == 1 && $0 == "---" { in_fm = 1; next }
        in_fm && $0 == "---" { exit }
        in_fm && $0 ~ ("^" field ":") {
            sub("^[^:]+:[[:space:]]*", "")
            print
            exit
        }
    ' "$file"
}

workflow_stage_file_body() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    awk '
        NR == 1 && $0 == "---" { in_fm = 1; next }
        in_fm && $0 == "---" { in_fm = 0; next }
        !in_fm { print }
    ' "$file"
}

workflow_core_stage_file() {
    local stage="$1"
    echo "$CRAFT_ROOT/stages/$stage.md"
}

workflow_plugin_stage_file() {
    local plugin="$1" stage="$2"
    echo "$CRAFT_ROOT/plugins/$plugin/stages/$stage.md"
}

workflow_stage_provider_file() {
    local project_dir="$1" stage="$2"
    local file plugin plugin_file provider=""
    file="$(workflow_core_stage_file "$stage")"
    if [[ -f "$file" ]]; then
        provider="$file"
    fi
    while IFS= read -r plugin; do
        plugin_file="$(workflow_plugin_stage_file "$plugin" "$stage")"
        [[ -f "$plugin_file" ]] || continue
        if [[ -n "$provider" ]]; then
            echo "duplicate_stage_provider: $stage" >&2
            return 2
        fi
        provider="$plugin_file"
    done < <(plugin_enabled_plugins "$project_dir")
    [[ -n "$provider" ]] || return 1
    echo "$provider"
}

workflow_insert_after() {
    local list="$1" anchor="$2" stage="$3"
    awk -v anchor="$anchor" -v stage="$stage" '
        BEGIN { inserted = 0 }
        {
            print
            if ($0 == anchor && !inserted) {
                print stage
                inserted = 1
            }
        }
        END { if (!inserted) exit 2 }
    ' <<< "$list"
}

workflow_insert_before() {
    local list="$1" anchor="$2" stage="$3"
    awk -v anchor="$anchor" -v stage="$stage" '
        BEGIN { inserted = 0 }
        {
            if ($0 == anchor && !inserted) {
                print stage
                inserted = 1
            }
            print
        }
        END { if (!inserted) exit 2 }
    ' <<< "$list"
}

workflow_plugin_stage_insertions() {
    local project_dir="$1" workflow="$2" base_stages="$3"
    local plugin plugin_dir file stage insert workflow_owner position anchor
    while IFS= read -r plugin; do
        plugin_dir="$CRAFT_ROOT/plugins/$plugin"
        [[ -d "$plugin_dir" ]] || continue
        [[ -d "$plugin_dir/stages" ]] || continue
        while IFS= read -r file; do
            [[ -f "$file" ]] || continue
            stage="$(basename "$file" .md)"
            insert="$(workflow_stage_file_frontmatter "$file" insert)"
            workflow_owner="$(workflow_stage_file_frontmatter "$file" workflow)"
            if [[ -z "$insert" ]]; then
                if [[ -n "$workflow_owner" ]]; then
                    [[ "$workflow_owner" == "$workflow" ]] && continue
                    continue
                fi
                echo "plugin_stage_missing_insert: $plugin/$stage" >&2
                return 2
            fi
            if [[ -n "$workflow_owner" && "$workflow_owner" != "$workflow" ]]; then
                continue
            fi
            if grep -qxF -- "$stage" <<< "$base_stages"; then
                continue
            fi
            position="${insert%%:*}"
            anchor="${insert#*:}"
            [[ "$position" != "$insert" && -n "$anchor" ]] || { echo "invalid_stage_insert: $plugin/$stage $insert" >&2; return 2; }
            [[ "$position" == "before" || "$position" == "after" ]] || { echo "invalid_stage_insert: $plugin/$stage $insert" >&2; return 2; }
            if ! grep -qxF -- "$anchor" <<< "$base_stages"; then
                continue
            fi
            printf '%s\t%s\t%s\t%s\n' "$position" "$anchor" "$stage" "$plugin"
        done < <(find "$plugin_dir/stages" -maxdepth 1 -name '*.md' | sort)
    done < <(plugin_enabled_plugins "$project_dir")
}

workflow_resolve_stages() {
    local project_dir="$1" task_file="$2"
    local workflow stages position anchor stage plugin stage_file insertions_file
    workflow="$(workflow_task_workflow "$task_file")"
    stages="$(workflow_base_stages "$project_dir" "$workflow")" || return 1

    insertions_file="$(mktemp)"
    workflow_plugin_stage_insertions "$project_dir" "$workflow" "$stages" > "$insertions_file" || {
        rm -f "$insertions_file"
        return 2
    }

    while IFS=$'\t' read -r position anchor stage plugin; do
        [[ -n "$position" && -n "$anchor" && -n "$stage" ]] || continue
        if grep -qxF -- "$stage" <<< "$stages"; then
            echo "duplicate_stage_in_workflow: $stage" >&2
            rm -f "$insertions_file"
            return 2
        fi
        case "$position" in
            before)
                stages="$(workflow_insert_before "$stages" "$anchor" "$stage")" || {
                    echo "workflow_anchor_not_found: before $anchor for $plugin/$stage" >&2
                    rm -f "$insertions_file"
                    return 2
                }
                ;;
            after)
                stages="$(workflow_insert_after "$stages" "$anchor" "$stage")" || {
                    echo "workflow_anchor_not_found: after $anchor for $plugin/$stage" >&2
                    rm -f "$insertions_file"
                    return 2
                }
                ;;
        esac
    done < "$insertions_file"
    rm -f "$insertions_file"

    while IFS= read -r stage; do
        [[ -n "$stage" ]] || continue
        stage_file="$(workflow_stage_provider_file "$project_dir" "$stage")" || {
            echo "stage_definition_not_found: $stage" >&2
            return 2
        }
        [[ -f "$stage_file" ]] || return 2
    done <<< "$stages"

    printf '%s\n' "$stages"
}

workflow_stage_prompt_file() {
    local project_dir="$1" stage="$2"
    workflow_stage_provider_file "$project_dir" "$stage"
}

workflow_csv_lines() {
    local raw="$1"
    printf '%s\n' "$raw" | tr ',' '\n' | while IFS= read -r item; do
        item="$(echo "$item" | xargs)"
        [[ -n "$item" ]] && printf '%s\n' "$item"
    done
}

workflow_event_file() {
    local project_dir="$1" event="$2"
    local file plugin plugin_file provider=""
    file="$CRAFT_ROOT/events/$event.md"
    [[ -f "$file" ]] && provider="$file"
    while IFS= read -r plugin; do
        plugin_file="$CRAFT_ROOT/plugins/$plugin/events/$event.md"
        [[ -f "$plugin_file" ]] || continue
        if [[ -n "$provider" ]]; then
            echo "duplicate_event_provider: $event" >&2
            return 2
        fi
        provider="$plugin_file"
    done < <(plugin_enabled_plugins "$project_dir")
    [[ -n "$provider" ]] || return 1
    echo "$provider"
}

workflow_render_event_prompt() {
    local project_dir="$1" event="$2"
    local file plugin fragment
    file="$(workflow_event_file "$project_dir" "$event")" || { echo "event_definition_not_found: $event" >&2; return 2; }
    printf '\n### Event: %s\n\n' "$event"
    workflow_stage_file_body "$file"
    while IFS= read -r plugin; do
        fragment="$CRAFT_ROOT/plugins/$plugin/fragments/events/$event.md"
        if [[ -f "$fragment" ]]; then
            printf '\n#### Event Fragment: %s\n\n' "$plugin"
            workflow_stage_file_body "$fragment"
        fi
    done < <(plugin_enabled_plugins "$project_dir")
}

workflow_render_stage_prompt() {
    local project_dir="$1" stage="$2"
    local base plugin fragment events event fragment_events
    base="$(workflow_stage_prompt_file "$project_dir" "$stage")" || return 2
    workflow_stage_file_body "$base"
    events="$(workflow_stage_file_frontmatter "$base" events)"

    while IFS= read -r plugin; do
        fragment="$CRAFT_ROOT/plugins/$plugin/fragments/stages/$stage.md"
        if [[ -f "$fragment" ]]; then
            printf '\n### Stage Fragment: %s\n\n' "$plugin"
            workflow_stage_file_body "$fragment"
            fragment_events="$(workflow_stage_file_frontmatter "$fragment" events)"
            if [[ -n "$fragment_events" ]]; then
                events="${events}${events:+,}${fragment_events}"
            fi
        fi
    done < <(plugin_enabled_plugins "$project_dir")

    if [[ -n "$events" ]]; then
        printf '\n## Events For This Stage\n'
        while IFS= read -r event; do
            workflow_render_event_prompt "$project_dir" "$event"
        done < <(workflow_csv_lines "$events")
    fi
}

workflow_render_prompt() {
    local project_dir="$1" task_file="$2" filename="$3"
    local workflow options_json stages stage
    workflow="$(workflow_task_workflow "$task_file")"
    options_json="$(workflow_task_options_json "$task_file")"
    stages="$(workflow_resolve_stages "$project_dir" "$task_file")" || return 1

    cat <<EOF
NOTE: Craft rendered this prompt from the task's resolved workflow. Follow the assembled stages below rather than any fixed /work-task step list. If the orchestrator already moved the task to in-progress, do not move it again.

# /workflow — ${workflow}

You are executing a Craft workflow preset. Follow the stages below in order. Stage prompt fragments are advisory instructions for the agent; deterministic side effects belong in script hooks.

Task file: ${task_file#"$project_dir/"}
Workflow: ${workflow}
Workflow options:
\`\`\`json
${options_json}
\`\`\`
Resolved stages:
$(printf '%s\n' "$stages" | sed 's/^/- /')

## Before The First Stage

Read the task file and parse its frontmatter before acting: \`id\`, \`type\`, \`milestone\`, \`depends_on\`, \`repos\`, \`branch\`, \`base\`, \`qa\`, \`pr\`, and any workflow options.

Read project context first:

- \`docs/plan.md\`
- the milestone doc named by the task's \`milestone:\` field, when present
- any ADRs referenced by the task or milestone
- \`state.md\`
- \`.claude/CLAUDE.md\`, when present

If \`depends_on\` names a task that is not in \`queue/done/\` or \`queue/archive/\`, stop immediately and block the task:

\`\`\`bash
craft task stage block <task-id> --reason "unmet dependency: <task-id>"
\`\`\`

Set up repository worktrees before code work. For each repo in \`repos:\`, create or reuse \`tasks/<task-id>/<repo>/\` from the main clone at \`repos/<repo>\` or \`~/code/<repo>\`. Use the task's \`branch:\` and \`base:\` fields; default the base ref to \`origin/main\` when \`base:\` is absent. If the worktree does not exist, run \`git -C <main-clone> worktree add <task-dir>/<repo> -b <branch> <base-ref>\`; if the branch already exists, add the worktree for the existing branch instead. Create \`tasks/<task-id>/<repo>/.orchestrator/\` so plugin hooks can find the worktree. Do all code work inside these task worktrees, never in \`repos/\` or \`~/code/\`.

Use the task's \`branch:\` exactly. Commit messages must be conventional (\`feat:\`, \`fix:\`, \`refactor:\`, etc.) and should not include task IDs. Use \`git push --force-with-lease\` after rewritten history; never plain \`--force\`.

Never merge a PR yourself. When querying GitHub for an existing PR from this branch, scope checks to open PRs, for example \`gh pr list --state open --head <branch>\`.

EOF

    while IFS= read -r stage; do
        [[ -n "$stage" ]] || continue
        printf '\n## Stage: %s\n\n' "$stage"
        workflow_render_stage_prompt "$project_dir" "$stage"
        printf '\n'
    done <<< "$stages"
}
