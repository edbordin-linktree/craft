---
events: merge_status,ci_status,review_comment,pr_approval,pr_review
---
The PR review plugin may enqueue typed events for merge status, CI, review comments, approvals, and PR state changes. Drain pending events with `craft event take` when Craft wakes you.
