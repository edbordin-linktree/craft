#!/usr/bin/env bash
# mux.sh — Multiplexer abstraction layer
#
# Sources either tmux.sh or cmux.sh based on the MULTIPLEXER config.
# All multiplexer providers must implement these functions:
#
#   ensure_session <project-name> <project-dir>
#     → Create/find a session with orchestrator + architect windows.
#       Returns the session/workspace identifier.
#
#   ensure_task_session <project-name> <task-id> [task-dir]
#     → Create/find a per-task session/workspace. Under cmux this is a
#       separate workspace at <CMUX_PREFIX>-<project>-<task-id>, opened with
#       --cwd=<task-dir>. Under tmux this is the project session (tmux has
#       no workspace concept; the task gets its own window inside it).
#       Returns the session/workspace identifier.
#
#   spawn_task_pane <session> <task-id> <prompt-file> <work-dir> [agent]
#     → Create a new pane/surface and run the agent command in it.
#       Returns a pane/surface identifier.
#
#   resume_task_pane <session> <task-id> <prompt-file> <work-dir> [agent]
#     → Create a new pane/surface and run the provider's resume command in it.
#       Returns a pane/surface identifier.
#
#   pane_is_running <session> <task-id>
#     → Returns 0 if the task's pane is still alive, 1 if finished.
#
#   kill_task_pane <session> <task-id>
#     → Clean up a task's pane/surface.
#
# Generic primitives (used by skills, not by the orchestrator itself):
#
#   mux_spawn_named_pane <session> <name> <cwd> <cmd>
#     → Create a new pane/surface labeled <name>, cd into <cwd>, run <cmd>.
#       Idempotent: if a pane with this name already exists, no-op.
#
#   mux_send_to_pane <session> <name> <text>
#     → Send <text> + Enter to the named pane. Used to deliver follow-up
#       messages to persistent agent sessions (claude --resume, codex resume).
#
#   mux_pane_exists <session> <name>
#     → Returns 0 if the named pane exists, 1 otherwise.
#
#   mux_kill_named_pane <session> <name>
#     → Remove the named pane.
#
#   mux_surface_open <project-dir> <task-id> <surface-id> [--url URL ...]
#   mux_surface_focus <project-dir> <task-id> <surface-id>
#   mux_surface_close <project-dir> <task-id> <surface-id>
#     → Manage logical task surfaces. cmux owns browser surfaces; tmux returns
#       a clean unsupported status.
#
#   mux_task_status_set <project-name> <task-id> <status> <icon> <color>
#     → Set a visible task status banner. cmux writes a workspace status pill;
#       tmux is a no-op.
#
#   mux_replace_orchestrator_workspace <project-name> <project-dir> <command>
#     → Optional provider hook. Replace the project orchestrator workspace with
#       a freshly bootstrapped workspace running <command>.
#
#   mux_adopt_current_orchestrator_workspace <project-name> <project-dir>
#     → Optional provider hook. If the current process is already running
#       inside a multiplexer surface created for this project launch, mark that
#       workspace/surface as the orchestrator instead of creating another one.

MUX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default to tmux if not set
MULTIPLEXER="${MULTIPLEXER:-tmux}"

case "$MULTIPLEXER" in
    tmux)
        source "$MUX_DIR/mux-tmux.sh"
        ;;
    cmux)
        source "$MUX_DIR/mux-cmux.sh"
        ;;
    *)
        echo "Error: unknown multiplexer '$MULTIPLEXER'. Supported: tmux, cmux" >&2
        exit 1
        ;;
esac
