# plan-reviewer — provenance

`SKILL.md` and `references/` are copied verbatim from
[mblode/agent-skills/skills/plan-reviewer](https://github.com/mblode/agent-skills/tree/main/skills/plan-reviewer),
MIT-licensed (© 2026 Matthew Blode). Full license text in `LICENSE-MBLODE.md`
in this directory.

This skill is an adversarial rubber-duck dialogue for **strengthening
implementation plans** before coding starts. It scores a plan along six
dimensions (completeness, feasibility, scope, testability, risk, assumptions),
then asks pointed questions on the weakest 2-3 — directly editing the plan
file to record resolutions and unresolved gaps.

In craft's flow, the **architect** invokes this skill whenever it's asked to
plan or stress-test a task. The architect is loaded into the project workspace
via `init-architect.md` (which we patch to reference this skill).

`scripts/review-pr` (the cross-model code reviewer) is the sibling skill for
**code** review; `plan-reviewer` is the **plan** counterpart — same author,
same conventions, applied at the opposite end of the lifecycle.
