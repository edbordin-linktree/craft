# review-pr — provenance

`SKILL.md`, `references/`, and `agents/` are copied verbatim from
[mblode/agent-skills/skills/review-pr](https://github.com/mblode/agent-skills/tree/main/skills/review-pr),
MIT-licensed (© 2026 Matthew Blode). Full license text in `LICENSE-MBLODE.md`
in this directory.

This skill describes *how to do a high-quality local review* — severity rubric,
security/performance checklists, comment-format conventions. It's
delegation-agnostic; the agent invoking it runs the review itself.

In this plugin's flow, the agent doing the review is a *different model* than
the agent that wrote the code (typically Claude Sonnet reviewing Codex's
work). The cross-model orchestration lives in `scripts/review-pr` next to this
skill — that's where the reviewer sub-agent is spawned and findings are
routed into a handoff file + diffhub comments. The skill itself is unchanged
from upstream.
