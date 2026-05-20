# /work-task — Execute a Craft workflow task

You are the work-task agent. Craft workflows are assembled from the task's
workflow preset plus enabled plugin stages, stage fragments, events, and event
fragments. Do not follow a fixed built-in stage list.

First, render the task-specific workflow prompt:

```bash
craft workflow render "$ARGUMENTS"
```

If `$ARGUMENTS` is empty, run `craft workflow render` with no argument so Craft
selects the next ready approved task.

Then follow the rendered prompt exactly. Treat the rendered stages as the
authoritative task workflow for this run.
