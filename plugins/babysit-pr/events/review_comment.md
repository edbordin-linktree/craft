---
---
`review_comment` reports a PR comment or review thread.

Triage comments critically. For each actionable inline review thread:

1. Make the code change.
2. Commit and push it, then capture the short commit SHA.
3. Reply to the existing thread with the fix commit.
4. Resolve the thread via GraphQL `resolveReviewThread`.
5. Verify the thread no longer appears in `reviewThreads { isResolved: false }`.

Issue-level PR comments do not have a resolvable review-thread object; reply to those when needed and record the outcome. For non-actionable inline threads, reply with the reason, resolve the thread, and verify it is resolved.
