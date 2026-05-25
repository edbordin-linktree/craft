---
queue_state: waiting
---
Open and monitor the pull request for this task.

If the task frontmatter does not already have `pr:`, create the GitHub PR from the task branch:

1. Ensure the branch is pushed to origin.
2. Check for an existing open PR with `gh pr list --state open --head <branch>`.
3. If none exists, create a draft PR with a conventional title and a body containing the change summary, QA results, and manual validation notes. Assign `GITHUB_REVIEWER` when configured.
4. Mark the PR ready for review after creation; local review, when configured, has already happened before this stage.
5. Record the PR URL on the task with `craft task state set <task-id> waiting --reason "PR opened" --set pr=<pr-url> --log "PR Opened" --log-body "PR: <pr-url>"`.
6. Re-enter this stage with `craft task stage set <task-id> pr_review --reason "PR recorded"` so PR-stage plugin hooks can open surfaces and start watchers using the recorded `pr:`.

Handle merge conflicts, CI failures, and review comments. Never merge the PR yourself.
