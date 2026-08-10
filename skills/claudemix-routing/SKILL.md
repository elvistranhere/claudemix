---
name: claudemix-routing
description: Choose the right model lane when delegating subagent work in a claudemix mixed-model session. Use whenever spawning executor subagents and more than one lane (sol/terra/luna/spark, or Claude models) could plausibly take the task.
---

# claudemix lane routing

You are the orchestrator; the lanes are executors. Route by workload shape, verify by log, never by model self-report.

## The decision in four questions

1. **Does it need frontier judgment under ambiguity** (root-cause analysis, subtle correctness, adversarial verification)? Keep it on the Claude side: your own turn, or an opus-pinned subagent. Do not outsource judgment to an executor lane.
2. **Is it well-specified executor work** (implement to a spec, write tests to a contract, refactor with clear done-criteria)? Default `terra`. Escalate to `sol` only when the task is genuinely hard: many interacting files, long tool-call horizons, gnarly debugging execution.
3. **Is it bulk and mechanical** (sweeps, renames, formatting, many small independent transforms)? `luna`, fanned out. Falls over on multi-step judgment; keep each unit trivial.
4. **Is it tiny and latency-sensitive** (one-file tweak, quick review pass)? `spark`. Hard limits: small context, pair-programmer mode; if the task needs more than a few steps, use terra instead.

Claude fast lanes still exist and are often right: sonnet for reading/exploration/summarizing, haiku for trivial lookups. The GPT lanes' edge is that they spend the Codex budget, not the Claude one; when Claude usage is the constraint, shift executor volume to terra/luna.

## Rules that survive contact

- Lanes exist only in claudemix sessions (the splitter routes gpt-* models). In a plain session those agent types either do not exist or will error; check before promising them.
- A lane's model comes from its agent-definition frontmatter. Inline `model` params cannot select gpt models.
- Model and effort are separate dials. Each lane pins a default `effort` in frontmatter, which becomes `reasoning.effort` upstream; a lane with no effort silently runs at `xhigh`.
- In a Workflow, override the default per call: `agent(prompt, {agentType: 'sol', effort: 'low'})`. Use this when the task needs a particular model's capability but not its default depth, or the reverse. The Agent tool has no effort parameter, so there you must pick a lane whose pinned effort already fits (generate variants with `CLAUDEMIX_LANES` if you need more).
- Verify effort like routing, from the log: `grep cliproxy ~/.local/state/claudemix/splitter.log` shows `model=<lane> effort=<level>` per request.
- Brief executor lanes tightly: exact paths, exact done-criteria, "return evidence, not a dump". They execute; they do not re-plan.
- Bound the input, not the ambition. Long multi-file builds are what `sol` is for; what kills a lane is open-ended *reading*, not a long task. A brief that says "read what you need" or "run the diff and review it" lets a lane read until it overruns its window, and the task dies with `Prompt is too long` rather than degrading. Observed: four lanes given an open-ended review brief all died; the same review with three named files and "read nothing else" ran fine in 24k tokens. Name the files, or hand over the excerpt yourself, then let the lane work as long as the job needs.
- Verify routing on first use of any lane in a session: `grep cliproxy ~/.local/state/claudemix/splitter.log` must show `model=<expected> status=200`. Never trust "I am GPT/Claude" claims.
- Verify lane output like any subagent report: read the diff, run the checks. Executor reports are optimistic regardless of vendor.
- Long-context outlier (whole-repo reads beyond every lane): gpt-5.4 serves ~1M tokens; no standing lane, pin it in a one-off agent definition if truly needed.
- If a lane errors or degrades (429s from Codex limits, empty outputs), fall back one step: spark→terra, luna→terra, terra→sol, sol→Claude opus. Note the fallback in your report.
