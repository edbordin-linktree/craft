---
---
Diffhub comments include the current file, line, `comment_id`, and `diffhub_url` when available. Ignore comments marked stale by the Diffhub watcher; act only on events delivered by Craft.

After handling a Diffhub comment, respond on the existing thread through the comments API instead of creating a new top-level comment:

```bash
curl -fsS -X PATCH "$diffhub_url/api/comments?id=$comment_id" \
  -H 'content-type: application/json' \
  -d '{"action":"reply","body":"Fixed in <short-sha>: <brief response>"}'
curl -fsS -X PATCH "$diffhub_url/api/comments?id=$comment_id" \
  -H 'content-type: application/json' \
  -d '{"action":"resolve"}'
```

If no code change is needed, reply with the reason and then resolve the Diffhub comment. Diffhub reply updates are intentionally not forwarded back as new local-review events.
