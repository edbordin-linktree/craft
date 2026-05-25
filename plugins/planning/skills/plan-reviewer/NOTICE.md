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

In craft's flow, a planning agent invokes this skill whenever it is asked to
plan or stress-test a task. It is intentionally limited to plan quality and
does not prescribe the execution workflow.
