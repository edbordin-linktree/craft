---
queue_state: in-progress
---
Run the automated QA specified by the task frontmatter:

- `unit_tests: true`: run the repository unit tests.
- `integration_tests: true`: run integration tests.
- `local_validation: "command"`: run that command and verify it succeeds.
- `qa_env: true` or `prod_validation: true`: do not attempt real environment validation; add a Work Log note flagging it for the operator.

If an automated QA step fails twice and cannot be fixed, mark the task blocked with details.

When automated QA is complete, commit all task changes with a conventional commit message. If the branch already has commits for this task, amend or add a focused follow-up commit according to the smallest clear history. Push the task branch before entering PR review.
