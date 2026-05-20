#!/usr/bin/env bash
# queue.sh — Queue manipulation helpers for the craft orchestrator

# Portable sed -i wrapper (macOS vs GNU)
_sed_i() {
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i -E "$@"
    else
        sed -i "" -E "$@"
    fi
}

# Get the value of a YAML frontmatter field from a task file
# Usage: task_field <file> <field>
task_field() {
    local file="$1" field="$2"
    sed -n '/^---$/,/^---$/p' "$file" | grep "^${field}:" | sed "s/^${field}:[[:space:]]*//"
}

# Get the task ID from a task file
task_id() {
    task_field "$1" "id"
}

# Get the task status from a task file
task_status() {
    task_field "$1" "status"
}

# Get the task milestone from a task file
task_milestone() {
    task_field "$1" "milestone"
}

# Get the task type from a task file
task_type() {
    task_field "$1" "type"
}

task_workflow() {
    local workflow
    workflow="$(task_field "$1" "workflow")"
    printf '%s\n' "${workflow:-standard-pr}"
}

task_parent() {
    task_field "$1" "parent"
}

task_title() {
    task_field "$1" "title"
}

# Human label for a queue state directory name.
queue_state_label() {
    local state="$1"
    local word label=""
    state="${state//-/ }"
    state="${state//_/ }"
    for word in $state; do
        label+="${word^} "
    done
    printf '%s' "${label% }"
}

# Derive a short, human-readable title for sidebar display. Priority:
#   1. Explicit `title:` field in frontmatter
#   2. First non-blank, non-bullet line of the `## Summary` section
#   3. Empty string (caller falls back to bare task id)
# Output is trimmed and capped at 60 chars (with ellipsis if truncated).
task_human_title() {
    local file="$1"
    local raw
    raw=$(task_field "$file" "title")
    if [[ -z "$raw" ]]; then
        raw=$(awk '
            /^## Summary[[:space:]]*$/ { in_section = 1; next }
            /^## / && in_section { exit }
            in_section {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "")
                if ($0 == "" || /^- / || /^\* / || /^[0-9]+\. /) next
                print
                exit
            }
        ' "$file")
    fi
    # Strip surrounding quotes if explicit title was quoted.
    raw="${raw#\"}"
    raw="${raw%\"}"
    raw="${raw#\'}"
    raw="${raw%\'}"
    # Cap length.
    if (( ${#raw} > 60 )); then
        raw="${raw:0:57}…"
    fi
    printf '%s' "$raw"
}

# Get depends_on as a space-separated list
# Handles both inline [a, b] and multi-line - a\n- b YAML formats
task_depends_on() {
    local file="$1"
    local raw
    raw=$(task_field "$file" "depends_on")

    # Inline format: [task-001, task-002]
    if [[ "$raw" == "["*"]" ]]; then
        echo "$raw" | tr -d '[]' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$'
        return
    fi

    # Multi-line format: depends_on:\n  - task-001
    sed -n '/^depends_on:/,/^[a-z]/p' "$file" | grep '^ *-' | sed 's/^ *- *//'
}

task_workflow_options_json() {
    local file="$1"
    awk '
        /^workflow_options:[[:space:]]*$/ { in_opts = 1; next }
        in_opts && /^[^[:space:]]/ { exit }
        in_opts && /^[[:space:]]+[A-Za-z0-9_.-]+:/ {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            key = line
            sub(/:.*/, "", key)
            value = line
            sub(/^[^:]+:[[:space:]]*/, "", value)
            gsub(/^["'\''"]|["'\''"]$/, "", value)
            print key "\t" value
        }
    ' "$file" | jq -cRn '
        reduce inputs as $line ({};
          ($line | split("\t")) as $p
          | .[$p[0]] =
              ($p[1]
               | if . == "true" then true
                 elif . == "false" then false
                 elif . == "null" then null
                 elif test("^-?[0-9]+$") then tonumber
                 else .
                 end))
    '
}

# Check if all dependencies of a task are satisfied (in done/ or archive/)
# Returns 0 if all deps are met, 1 if not
task_deps_met() {
    local file="$1"
    local queue_dir="$(dirname "$(dirname "$file")")"
    local deps
    deps=$(task_depends_on "$file")

    if [[ -z "$deps" ]]; then
        return 0
    fi

    for dep in $deps; do
        local found=0
        # Check done/
        for done_file in "$queue_dir/done"/*.md "$queue_dir/archive"/**/*.md; do
            [[ -f "$done_file" ]] || continue
            if [[ "$(task_id "$done_file")" == "$dep" ]]; then
                found=1
                break
            fi
        done
        if [[ $found -eq 0 ]]; then
            return 1
        fi
    done
    return 0
}

# Move a task file between queue directories and update its status
# Usage: move_task <file> <new-status-dir> <new-status>
move_task() {
    local file="$1" target_dir="$2" new_status="$3"
    local filename="$(basename "$file")"
    local target="$target_dir/$filename"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    # Update status in frontmatter
    _sed_i "s/^status:.*/status: $new_status/" "$file"

    # Set timestamp for the target status
    case "$new_status" in
        in-progress)
            _sed_i "s/^started:.*/started: $timestamp/" "$file"
            ;;
        waiting)
            _sed_i "s/^waiting:.*/waiting: $timestamp/" "$file"
            ;;
        done)
            _sed_i "s/^done:.*/done: $timestamp/" "$file"
            ;;
        blocked)
            _sed_i "s/^blocked:.*/blocked: $timestamp/" "$file"
            _sed_i "s/^one_shot:.*/one_shot: false/" "$file"
            ;;
    esac

    # Move the file
    mv "$file" "$target"
    echo "$target"
}

# List all task files in a queue directory, sorted by ID
# Usage: list_tasks <directory>
list_tasks() {
    local dir="$1"
    find "$dir" -maxdepth 1 -name '*.md' -not -name '.gitkeep' 2>/dev/null | sort
}

# Count tasks in a directory
count_tasks() {
    local dir="$1"
    list_tasks "$dir" | wc -l | tr -d ' '
}

# Get the next approved task that has all dependencies met
# Usage: next_ready_task <queue-dir>
next_ready_task() {
    local queue_dir="$1"
    for task in $(list_tasks "$queue_dir/approved"); do
        if [[ "$(task_type "$task")" == "plan" ]]; then
            continue
        fi
        if task_deps_met "$task"; then
            echo "$task"
            return 0
        fi
    done
    return 1
}

promote_draft_task() {
    local queue_dir="$1" task_id="$2"
    local src="$queue_dir/drafts/$task_id.md"
    local dst_dir="$queue_dir/pending"
    local dst="$dst_dir/$task_id.md"
    [[ -f "$src" ]] || { echo "draft_not_found: $task_id" >&2; return 1; }
    mkdir -p "$dst_dir"
    _sed_i "s/^status:.*/status: pending/" "$src"
    mv "$src" "$dst"
    echo "$dst"
}

# Append a timestamped entry to a task's work log
# Usage: append_work_log <file> <message>
append_work_log() {
    local file="$1" message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "" >> "$file"
    echo "### $message — $timestamp" >> "$file"
}
