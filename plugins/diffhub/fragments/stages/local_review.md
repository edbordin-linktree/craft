---
---
Diffhub may be available during this stage as the local review surface. Comments from the UI and automated local reviewers arrive as `local_review.comment` events.

For Diffhub-backed comments, completing the work includes replying to the existing Diffhub thread and resolving it through `PATCH /api/comments?id=<comment_id>`. Do not publish a fresh top-level comment as the response to an existing Diffhub comment.
