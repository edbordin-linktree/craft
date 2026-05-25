---
insert: before:pr_review
events: local_review.comment,review_timeout
queue_state: local-review
---
Run local review for the current task.

Assess every review comment on its merits. Make code changes for actionable correctness, safety, test, or maintainability issues; explain why you are not changing anything for comments that do not apply.

Do not treat a clean automated review as approval. Continue only when the operator advances the task, a configured review timeout event says to continue, or the stage is otherwise explicitly transitioned.
