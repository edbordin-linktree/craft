# babysit-pr references

These files are copied from
[`mblode/agent-skills/skills/babysit-pr/references`](https://github.com/mblode/agent-skills/tree/main/skills/babysit-pr/references),
MIT-licensed (© 2026 Matthew Blode). The full license text is in
`LICENSE-MBLODE.md` alongside this README — keep both files together if you
redistribute.

The SKILL.md in the parent directory points at these files at specific phases
(load `references/ci-platforms.md` during phase 3, etc.). They encode
hard-won tool-specific knowledge — CI log-fetch commands, GraphQL queries for
review threads, bot-noise patterns — that the agent would otherwise have to
discover at runtime.

## Files

| File | Used at |
|---|---|
| `bot-patterns.md` | Phase 4 — bot detection, severity parsing, noise classification |
| `ci-platforms.md` | Phase 3 — per-platform commands (GitHub Actions, Buildkite, Vercel, Fly.io) |
| `fix-plan-template.md` | Phase 4 — comment-triage plan-doc template |
| `github-api.md` | Phase 4 — GraphQL queries for fetching, replying, resolving threads |
| `merge-conflicts.md` | Phase 2 — conflict resolution strategy |
| `monitoring-setup.md` | Reference only — describes the upstream's CronCreate flow, which we replace with craft's inline while-loop. Kept for context. |

## Local edits

We don't edit these files in-place. If a reference needs tuning for our
context (e.g. specific Buildkite tokens, our bot accounts), prefer adding a
sibling file like `ci-platforms-blstrco.md` and pointing the SKILL.md at it
for the relevant phase.
