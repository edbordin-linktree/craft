---
insert: before:pr_review
events: local_review.comment,review_timeout
queue_state: local-review
---
Run local review for the current task.

Assess every review comment on its merits. Make code changes for actionable correctness, safety, test, or maintainability issues; explain why you are not changing anything for comments that do not apply.

When Craft wakes you with `CRAFT_EVENTS`, use `craft event list` to inspect pending local-review events without consuming them, or `craft event take --type local_review.comment --limit <n>` / `craft event take --type review_timeout --limit <n>` to read and consume them. Inside the task workspace, omit the task id.

Do not treat a clean automated review as approval. Continue only when the operator advances the task, a configured review timeout event says to continue, or the stage is otherwise explicitly transitioned.
