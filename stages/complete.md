---
queue_state: done
---
Only enter this stage after the task's pull request is merged or the task has otherwise reached its configured successful terminal condition.

Mark the task complete, append a completion Work Log entry with the PR URL and QA summary when applicable, update `state.md`, and leave worktrees in place for the operator to clean up.

After the task is complete and cleanup hooks have run, end the agent session so the orchestrator can tear down the pane.
