---
events: merge_status,ci_status,review_comment,pr_approval,pr_review
---
The `babysit-pr` plugin watches the GitHub PR during this stage and enqueues typed events when attention may be needed.

Drain pending events with `craft event take` when Craft wakes you. Treat each event as a notification about a GitHub update, not as approval to merge:

- `merge_status`: mergeability or base-branch changes. Rebase or resolve conflicts when actionable.
- `ci_status`: check-run/status transitions. Diagnose failures, fix, commit, and push.
- `review_comment`: PR comments or review threads. Triage critically; every handled inline thread needs a reply, `resolveReviewThread`, and a verification that it is no longer unresolved.
- `pr_approval`: human approval state. Record it, but never merge the PR yourself.
- `pr_review`: PR lifecycle updates such as draft/ready, merged, or closed.
