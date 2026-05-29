#!/usr/bin/env bash
set -uo pipefail

# Requires bash 4+ for associative arrays.
if [[ ${BASH_VERSINFO[0]:-0} -lt 4 ]]; then
    echo "orchestrator.sh requires bash 4+ (you have ${BASH_VERSION:-unknown}). On macOS: 'brew install bash' then ensure /opt/homebrew/bin (or /usr/local/bin) is earlier on PATH than /bin." >&2
    exit 1
fi

# Self-derive CRAFT_ROOT from this script's path if it isn't already exported.
# The orchestrator can be re-exec'd into a fresh shell (e.g. cmux/tmux panes)
# that doesn't inherit the parent process env, so we can't rely on bin/craft's
# export reaching us.
if [[ -z "${CRAFT_ROOT:-}" ]]; then
    _ORCH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CRAFT_ROOT="$(cd "$_ORCH_SCRIPT_DIR/.." && pwd)"
    export CRAFT_ROOT
fi

# orchestrator.sh — Persistent daemon that processes the craft task queue
#
# Usage: orchestrator.sh <project-dir> [--max-parallel N]
#
# Watches the queue for approved tasks, spins up Claude sessions in tmux panes,
# monitors task lifecycle, and notifies on state changes.
#
# Run this in a tmux pane — it becomes the orchestrator dashboard.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/queue.sh"
source "$SCRIPT_DIR/lib/plugins.sh"
source "$SCRIPT_DIR/lib/notify.sh"
source "$SCRIPT_DIR/lib/runtime.sh"
source "$SCRIPT_DIR/lib/workflow.sh"
source "$SCRIPT_DIR/lib/providers.sh"
# Multiplexer loaded after config (needs MULTIPLEXER variable)

# --- Logging ---
LOG_FILE=""  # set after PROJECT_DIR is known

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    [[ -n "$LOG_FILE" ]] && echo "$msg" >> "$LOG_FILE"
}

# --- Configuration ---
PROJECT_DIR=""
MAX_PARALLEL=10
POLL_INTERVAL=15  # seconds between queue checks
PR_POLL_INTERVAL=120  # seconds between PR merge checks

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-parallel)
            MAX_PARALLEL="$2"
            shift 2
            ;;
        --poll-interval)
            POLL_INTERVAL="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 <project-dir> [--max-parallel N] [--poll-interval SECONDS]"
            exit 0
            ;;
        *)
            PROJECT_DIR="$1"
            shift
            ;;
    esac
done

if [[ -z "$PROJECT_DIR" ]]; then
    echo "Error: project directory required"
    echo "Usage: $0 <project-dir> [--max-parallel N]"
    exit 1
fi

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
QUEUE_DIR="$PROJECT_DIR/queue"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
# Export for child processes (run-hook.sh, task agents, etc.) — they need to
# know which project they're operating on.
export PROJECT_DIR PROJECT_NAME

# Validate project structure
mapfile -t QUEUE_STATES < <(plugin_queue_states "$PROJECT_DIR")
for dir in "${QUEUE_STATES[@]}"; do
    mkdir -p "$QUEUE_DIR/$dir"
done
QUEUE_STATES_CONFIG_MTIME="$(date -r "$PROJECT_DIR/craft.conf" '+%s' 2>/dev/null || echo 0)"
mkdir -p "$PROJECT_DIR/worktrees"   # legacy layout (pre-nested-task-dir tasks)
mkdir -p "$PROJECT_DIR/tasks"        # new layout: per-task dir holds worktrees + state
mkdir -p "$PROJECT_DIR/.state/waiting"
mkdir -p "$PROJECT_DIR/logs"

# Initialize log file
LOG_FILE="$PROJECT_DIR/logs/orchestrator-$(date '+%Y-%m-%d').log"

# Load agent provider config (sets DEFAULT_AGENT, ARCHITECT_AGENT, MULTIPLEXER)
load_provider_config "$PROJECT_DIR"

# Load multiplexer provider (must come after config so MULTIPLEXER is set)
source "$SCRIPT_DIR/lib/mux.sh"

# --- State tracking ---
declare -A ACTIVE_TASKS=()   # task_id -> pane/window identifier
declare -A TASK_SESSIONS=()  # task_id -> session/workspace title (per-task under cmux, project session under tmux)
declare -A TASK_AGENTS=()    # task_id -> agent provider (claude, codex, etc.)
declare -A TASK_PR_URLS=()   # task_id -> PR URL (for merge monitoring)
declare -A TASK_START=()     # task_id -> epoch timestamp when task started

# --- Display ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

clear_screen() {
    # Use ANSI escape to clear without triggering tmux activity detection
    printf '\033[2J\033[H'
}

render_dashboard() {
    clear_screen

    echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  CRAFT ORCHESTRATOR — ${CYAN}${PROJECT_NAME}${NC}${BOLD}$(printf '%*s' $((28 - ${#PROJECT_NAME})) '')║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Counts
    local counts_line="" state count icon color label
    local -A queue_counts=()
    for state in "${QUEUE_STATES[@]}"; do
        [[ "$state" == "archive" ]] && continue
        count=$(count_tasks "$QUEUE_DIR/$state")
        queue_counts["$state"]="$count"
        case "$state" in
            drafts)      icon="◌"; color="$BLUE" ;;
            pending)     icon="○"; color="$BLUE" ;;
            approved)    icon="◐"; color="$YELLOW" ;;
            in-progress) icon="●"; color="$CYAN" ;;
            waiting)     icon="◉"; color="$YELLOW" ;;
            done)        icon="✓"; color="$GREEN" ;;
            blocked)     icon="✗"; color="$RED" ;;
            *)           icon="◇"; color="$YELLOW" ;;
        esac
        label=$(queue_state_label "$state")
        counts_line+="${color}${icon}${NC} ${label}: ${count}  "
    done
    echo -e "  ${counts_line%  }"
    echo ""

    # Waiting tasks — needs operator attention (PR review)
    local n_waiting="${queue_counts[waiting]:-0}"
    if [[ "$n_waiting" -gt 0 ]]; then
        echo -e "${BOLD}${YELLOW}  ◉ WAITING FOR REVIEW:${NC}"
        for task_file in $(list_tasks "$QUEUE_DIR/waiting"); do
            local tid pr_url
            tid=$(task_id "$task_file")
            pr_url=$(task_field "$task_file" "pr")
            if [[ -n "$pr_url" ]]; then
                echo -e "    ${YELLOW}◉${NC} $tid  ${CYAN}$pr_url${NC}"
            else
                echo -e "    ${YELLOW}◉${NC} $tid"
            fi
        done
        echo ""
    fi

    # Plugin-declared intermediate queue states.
    for state in "${QUEUE_STATES[@]}"; do
        case "$state" in
            drafts|pending|approved|in-progress|waiting|done|blocked|archive) continue ;;
        esac
        count="${queue_counts[$state]:-0}"
        [[ "$count" -gt 0 ]] || continue
        label=$(queue_state_label "$state")
        echo -e "${BOLD}${YELLOW}  ◇ ${label}:${NC}"
        for task_file in $(list_tasks "$QUEUE_DIR/$state"); do
            local tid
            tid=$(task_id "$task_file")
            echo -e "    ${YELLOW}◇${NC} $tid"
        done
        echo ""
    done

    # Blocked tasks (important — surface these prominently)
    local n_blocked="${queue_counts[blocked]:-0}"
    if [[ "$n_blocked" -gt 0 ]]; then
        echo -e "${BOLD}${RED}  ⚠ BLOCKED TASKS:${NC}"
        for task_file in $(list_tasks "$QUEUE_DIR/blocked"); do
            local tid
            tid=$(task_id "$task_file")
            echo -e "    ${RED}✗${NC} $tid — $(head -20 "$task_file" | grep '^## Summary' -A1 | tail -1 | sed 's/^[[:space:]]*//')"
        done
        echo ""
    fi

    # Active tasks
    if [[ ${#ACTIVE_TASKS[@]} -gt 0 ]]; then
        echo -e "${BOLD}  Active Tasks:${NC}"
        for task_id in "${!ACTIVE_TASKS[@]}"; do
            local agent_label="${TASK_AGENTS[$task_id]:-$DEFAULT_AGENT}"
            echo -e "    ${CYAN}●${NC} $task_id  [${agent_label}] [${MULTIPLEXER}: ${ACTIVE_TASKS[$task_id]}]"
        done
        echo ""
    fi

    # Approved tasks queued
    local n_approved="${queue_counts[approved]:-0}"
    if [[ "$n_approved" -gt 0 ]]; then
        echo -e "${BOLD}  Queue (approved):${NC}"
        for task_file in $(list_tasks "$QUEUE_DIR/approved"); do
            local tid dep_status
            tid=$(task_id "$task_file")
            if task_deps_met "$task_file"; then
                dep_status="${GREEN}ready${NC}"
            else
                dep_status="${YELLOW}waiting on deps${NC}"
            fi
            echo -e "    ${YELLOW}◐${NC} $tid  [$dep_status]"
        done
        echo ""
    fi

    # Recent done
    local n_done="${queue_counts[done]:-0}"
    if [[ "$n_done" -gt 0 ]]; then
        echo -e "${BOLD}  Recently Completed:${NC}"
        for task_file in $(list_tasks "$QUEUE_DIR/done" | tail -5); do
            local tid
            tid=$(task_id "$task_file")
            echo -e "    ${GREEN}✓${NC} $tid"
        done
        echo ""
    fi

    # Footer
    local now
    now=$(date '+%H:%M:%S')
    echo -e "  ${BOLD}Last poll:${NC} $now  ${BOLD}Parallel limit:${NC} $MAX_PARALLEL  ${BOLD}Poll interval:${NC} ${POLL_INTERVAL}s  ${BOLD}Agent:${NC} $DEFAULT_AGENT"
    echo -e "  ${BOLD}Ctrl+C${NC} to stop orchestrator"
}

# --- Task Execution ---

run_task() {
    local task_file="$1"
    local tid
    tid=$(task_id "$task_file")
    local filename
    filename=$(basename "$task_file")

    log "Starting task: $tid"

    # Mark as in-progress before rendering; the first workflow stage will
    # project the task into its configured queue state.
    local new_file
    new_file=$(runtime_queue_state_set_without_stage "$PROJECT_DIR" "$tid" "in-progress" "workflow started")
    # Build the prompt file. `skill:` keeps an explicit direct command dispatch
    # escape hatch; the default work-task path renders the resolved workflow.
    local skill_name="$(task_field "$new_file" "skill")"
    local configured_skill="${skill_name:-${TASK_SKILL:-}}"
    local prompt_file="/tmp/craft-prompt-${tid}.txt"
    if [[ -n "$configured_skill" && "$configured_skill" != "work-task" ]]; then
        local skill_file="$PROJECT_DIR/.claude/commands/${configured_skill}.md"
        {
            echo "NOTE: The orchestrator has already moved this task to queue/in-progress/${filename} and set its status to in-progress. Skip Step 2 (Move Task to In-Progress) — start from Step 1 (read context) then go straight to Step 3 (do the work)."
            echo ""
            sed "s/\\\$ARGUMENTS/$filename/g" "$skill_file"
        } > "$prompt_file"
    else
        if ! workflow_render_prompt "$PROJECT_DIR" "$new_file" "$filename" > "$prompt_file"; then
            log "Workflow prompt render failed for $tid"
            append_work_log "$new_file" "Blocked: workflow prompt render failed"
            runtime_stage_set "$PROJECT_DIR" "$tid" blocked "workflow prompt render failed" blocked >/dev/null || true
            return
        fi
        runtime_stage_advance "$PROJECT_DIR" "$tid" "workflow started" >/dev/null || log "Stage advance failed for $tid"
    fi

    # Determine which agent provider to use (task-level override or project default)
    local agent
    agent=$(task_agent "$new_file" "$PROJECT_DIR")
    local agent_model
    agent_model=$(task_agent_model "$new_file" "$PROJECT_DIR")

    # Ensure the project workspace (orchestrator + architect) exists. Idempotent.
    ensure_session "$PROJECT_NAME" "$PROJECT_DIR" >/dev/null

    # Pre-create the task directory. The agent will create worktrees as
    # subdirectories of this dir in Step 3 (e.g. tasks/<id>/<repo>/), so the
    # placeholder dir itself never collides with `git worktree add`.
    local task_dir="$PROJECT_DIR/tasks/$tid"
    mkdir -p "$task_dir"
    notify_started "$tid" "$new_file"

    # Per-task session (cmux: own workspace at task_dir; tmux: project session).
    # Pull a human-readable title from the task file so the cmux sidebar shows
    # something more memorable than the bare ID. Falls back to "" (bare id)
    # if no title/summary is present.
    local task_human_title
    task_human_title=$(task_human_title "$new_file")
    local task_session
    task_session=$(ensure_task_session "$PROJECT_NAME" "$tid" "$task_dir" "$task_human_title")

    # Spawn the agent in the task workspace, working in the task directory.
    local window
    window=$(spawn_task_pane "$task_session" "$tid" "$prompt_file" "$task_dir" "$agent" "$agent_model")

    # Track it
    ACTIVE_TASKS["$tid"]="$window"
    TASK_SESSIONS["$tid"]="$task_session"
    TASK_AGENTS["$tid"]="$agent"
    TASK_START["$tid"]="$(date +%s)"
}

# Find a task file by task ID across queue directories
find_task_in() {
    local dir="$1" tid="$2"
    for f in "$dir"/*.md; do
        [[ -f "$f" ]] || continue
        if [[ "$(task_id "$f")" == "$tid" ]]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

# Get the timeout for a task (per-task override or global default, in seconds)
# Returns empty string if no timeout is configured
task_timeout() {
    local tid="$1"
    local task_file=""

    # Find the task file in in-progress
    task_file=$(find_task_in "$QUEUE_DIR/in-progress" "$tid" 2>/dev/null || true)
    if [[ -n "$task_file" ]]; then
        local per_task
        per_task=$(task_field "$task_file" "timeout")
        if [[ -n "$per_task" ]]; then
            echo "$per_task"
            return
        fi
    fi

    echo "${AGENT_TIMEOUT:-}"
}

# Check if active tasks have finished or timed out
check_active_tasks() {
    local now
    now=$(date +%s)

    for tid in "${!ACTIVE_TASKS[@]}"; do
        # Per-task session (cmux: own workspace; tmux: project session). Fall
        # back to the project session if the map was never populated for this
        # task (legacy / edge case).
        local session="${TASK_SESSIONS[$tid]:-$SESSION}"

        # Check for timeout
        local timeout
        timeout=$(task_timeout "$tid")
        if [[ -n "$timeout" ]] && [[ -n "${TASK_START[$tid]:-}" ]]; then
            local elapsed=$(( now - TASK_START[$tid] ))
            if (( elapsed > timeout )); then
                log "Task $tid timed out after ${elapsed}s (limit: ${timeout}s)"

                local task_file
                task_file=$(find_task_in "$QUEUE_DIR/in-progress" "$tid" 2>/dev/null || true)
                if [[ -n "$task_file" ]]; then
                    append_work_log "$task_file" "Timed out by orchestrator after ${elapsed}s (limit: ${timeout}s)"
                    move_task "$task_file" "$QUEUE_DIR/blocked" "blocked" > /dev/null
                fi

                kill_task_pane "$session" "$tid"
                notify_blocked "$tid" "Agent timed out after ${elapsed}s" "$task_file"

                unset ACTIVE_TASKS["$tid"]
                unset TASK_SESSIONS["$tid"]
                unset TASK_AGENTS["$tid"]
                unset TASK_START["$tid"]
                continue
            fi
        fi

        if ! pane_is_running "$session" "$tid"; then
            log "Task $tid session ended"
            unset ACTIVE_TASKS["$tid"]
            unset TASK_SESSIONS["$tid"]
            unset TASK_AGENTS["$tid"]
            unset TASK_START["$tid"]

            # Check where the task ended up
            local ended_file
            if ended_file=$(find_task_in "$QUEUE_DIR/done" "$tid" 2>/dev/null); then
                log "Task $tid → done"
                notify_done "$tid" "" "$ended_file"
            elif ended_file=$(find_task_in "$QUEUE_DIR/blocked" "$tid" 2>/dev/null); then
                log "Task $tid → blocked"
                notify_blocked "$tid" "Task moved to blocked" "$ended_file"
            elif ended_file=$(find_task_in "$QUEUE_DIR/waiting" "$tid" 2>/dev/null); then
                log "Task $tid → waiting"
                notify_waiting "$tid" "$ended_file"
            else
                log "Task $tid session ended but task not found in done/blocked/waiting"
            fi

            # Clean up the pane (per-task session for cmux, project session for tmux)
            kill_task_pane "$session" "$tid"
        fi
    done
}

# Check for milestone completion
check_milestone_completion() {
    # Get all milestones that have tasks
    local milestones
    milestones=$(
        for dir in "${QUEUE_STATES[@]}"; do
            for f in "$QUEUE_DIR/$dir"/*.md; do
                [[ -f "$f" ]] && task_milestone "$f"
            done
        done | sort -u
    )

    for milestone in $milestones; do
        [[ -z "$milestone" ]] && continue

        # Check if all tasks for this milestone are done
        local all_done=true
        for dir in "${QUEUE_STATES[@]}"; do
            [[ "$dir" == "done" || "$dir" == "archive" ]] && continue
            for f in "$QUEUE_DIR/$dir"/*.md; do
                [[ -f "$f" ]] || continue
                if [[ "$(task_milestone "$f")" == "$milestone" ]]; then
                    all_done=false
                    break 2
                fi
            done
        done

        if $all_done; then
            # Check there are actually done tasks for this milestone
            local has_done=false
            for f in "$QUEUE_DIR/done"/*.md; do
                [[ -f "$f" ]] || continue
                if [[ "$(task_milestone "$f")" == "$milestone" ]]; then
                    has_done=true
                    break
                fi
            done

            if $has_done; then
                notify_milestone "$milestone"
                log "Milestone complete: $milestone — run /consolidate $milestone"
            fi
        fi
    done
}

# Check for new tasks in waiting state and notify
# Uses a marker file per task inside the project directory
check_waiting_tasks() {
    local marker_dir="$PROJECT_DIR/.state/waiting"
    mkdir -p "$marker_dir"
    for task_file in $(list_tasks "$QUEUE_DIR/waiting"); do
        local tid
        tid=$(task_id "$task_file")
        [[ -z "$tid" ]] && continue
        if [[ ! -f "$marker_dir/$tid" ]]; then
            touch "$marker_dir/$tid"
            notify_waiting "$tid" "$task_file"
            log "Task $tid is waiting for review"
        fi
    done
    # Clean up markers for tasks no longer in waiting
    for marker in "$marker_dir"/*; do
        [[ -f "$marker" ]] || continue
        local marker_tid
        marker_tid=$(basename "$marker")
        if ! find_task_in "$QUEUE_DIR/waiting" "$marker_tid" > /dev/null 2>&1; then
            rm -f "$marker"
        fi
    done
}

# --- Main Loop ---

# Handle nested tmux — if already inside tmux, unset TMUX to allow nesting
# and use a different prefix (C-b) for the inner session so keys don't collide
# with the outer session's prefix.
CRAFT_NESTED_TMUX=""
if [[ "$MULTIPLEXER" == "tmux" ]] && [[ -n "${TMUX:-}" ]] && [[ -z "${CRAFT_INNER_SESSION:-}" ]]; then
    CRAFT_NESTED_TMUX="$TMUX"
    unset TMUX
fi

# Under cmux: if this is the user's first invocation (CRAFT_INNER_SESSION unset),
# create/find the project's workspace and re-exec the orchestrator into that
# workspace's initial surface, so the dashboard lives next to the architect.
# Mirrors the tmux re-exec pattern. The invoking shell exits.
if [[ "$MULTIPLEXER" == "cmux" ]] && [[ -z "${CRAFT_INNER_SESSION:-}" ]]; then
    _cmd="CRAFT_INNER_SESSION=1 exec '$0' '$PROJECT_DIR' --max-parallel $MAX_PARALLEL --poll-interval $POLL_INTERVAL"
    if _initial="$(mux_bootstrap_orchestrator "$PROJECT_NAME" "$PROJECT_DIR" "$_cmd")" && [[ -n "$_initial" ]]; then
        exit 0
    fi
    # Fallback: couldn't find an initial surface — keep running in current terminal.
    echo "cmux: could not bootstrap orchestrator surface; running orchestrator in this terminal" >&2
fi

# Ensure multiplexer session with orchestrator + planner windows.
# Under cmux re-exec, we're now running inside the workspace's initial surface;
# create the architect surface only during this initial startup. Later health
# checks should not relaunch planning agents.
if [[ "$MULTIPLEXER" == "cmux" ]]; then
    CMUX_ENSURE_ARCHITECT=1 SESSION=$(ensure_session "$PROJECT_NAME" "$PROJECT_DIR")
    unset CMUX_ENSURE_ARCHITECT
else
    SESSION=$(ensure_session "$PROJECT_NAME" "$PROJECT_DIR")
fi

# If nested, set the inner session to use C-b so it doesn't collide with the outer prefix
if [[ -n "$CRAFT_NESTED_TMUX" ]]; then
    tmux set-option -t "$SESSION" prefix C-b 2>/dev/null || true
fi

# If using tmux and we're not already inside the session, re-exec inside the orchestrator pane
if [[ "$MULTIPLEXER" == "tmux" ]]; then
    if [[ -z "${TMUX:-}" ]] || [[ "$(tmux display-message -p '#{session_name}' 2>/dev/null)" != "$SESSION" ]]; then
        tmux send-keys -t "${SESSION}:orchestrator" "CRAFT_INNER_SESSION=1 exec '$0' '$PROJECT_DIR' --max-parallel $MAX_PARALLEL --poll-interval $POLL_INTERVAL" Enter
        exec tmux attach -t "$SESSION"
    fi
fi

log "Craft orchestrator starting for: $PROJECT_DIR"
log "Max parallel tasks: $MAX_PARALLEL, Poll interval: ${POLL_INTERVAL}s"
echo ""

trap 'log "Orchestrator stopped."; exit 0' INT TERM

poll_count=0

while true; do
    # Run plugin poll hooks (e.g. linear-sync inbound)
    queue_states_config_mtime="$(date -r "$PROJECT_DIR/craft.conf" '+%s' 2>/dev/null || echo 0)"
    if [[ "$queue_states_config_mtime" != "$QUEUE_STATES_CONFIG_MTIME" ]]; then
        mapfile -t QUEUE_STATES < <(plugin_queue_states "$PROJECT_DIR")
        for dir in "${QUEUE_STATES[@]}"; do
            mkdir -p "$QUEUE_DIR/$dir"
        done
        QUEUE_STATES_CONFIG_MTIME="$queue_states_config_mtime"
    fi
    plugin_sync_output=""
    if ! plugin_sync_output=$(plugin_sync_project_assets "$PROJECT_DIR" 2>&1); then
        log "Plugin project asset sync failed; continuing poll"
        while IFS= read -r plugin_sync_line; do
            [[ -n "$plugin_sync_line" ]] && log "  $plugin_sync_line"
        done <<< "$plugin_sync_output"
    fi
    _run_hook on_poll 2>/dev/null || true

    # Check finished tasks
    check_active_tasks

    # Check for new waiting tasks
    check_waiting_tasks

    # Check milestone completion every 4th poll
    if (( poll_count % 4 == 0 )); then
        check_milestone_completion
    fi

    # Keep cmux project surfaces healthy. This is intentionally idempotent:
    # for cmux it pins the workspace and starts/reuses the web dashboard tab;
    # for tmux this would be noisy, so keep it cmux-only.
    if [[ "$MULTIPLEXER" == "cmux" ]] && (( poll_count % 4 == 0 )); then
        ensure_session "$PROJECT_NAME" "$PROJECT_DIR" >/dev/null 2>&1 || true
    fi

    # Pick up new tasks if we have capacity
    active_count=${#ACTIVE_TASKS[@]}
    while (( active_count < MAX_PARALLEL )); do
        next_task=$(next_ready_task "$QUEUE_DIR") || break

        run_task "$next_task"
        active_count=$((active_count + 1))
    done

    # Render the dashboard
    render_dashboard

    # Sleep
    sleep "$POLL_INTERVAL"
    poll_count=$((poll_count + 1))
done
