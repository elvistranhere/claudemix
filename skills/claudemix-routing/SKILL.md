---
name: claudemix-routing
description: Choose between the GPT executor lanes (sol, terra) and keeping work on Claude when delegating in a claudemix mixed-model session. Use whenever spawning executor subagents for substantial work.
---

# claudemix lane routing

You orchestrate; the lanes execute. They run on the Codex subscription, so shifting executor volume to them spends a different budget than your own turns — which matters, because Claude rate limit is usually the scarce resource, not tokens.

## The decision

**Keep it on Claude** when the work is judgment under ambiguity: root-causing something you do not yet understand, deciding what to build, adversarial verification, anything where the answer's correctness is contested. Your own turn, or an opus subagent. Do not outsource the thinking.

**Delegate to a lane** when the work is substantial and the brief can be made complete: implement this feature, do this migration, write these tests to this contract, fix this failing suite. Lanes are for long-horizon execution, not errands — a task small enough to finish in a couple of tool calls is not worth the round trip of briefing one.

- `terra` is the default. Reach for it unless you have a reason not to.
- `sol` is for work that is genuinely hard: many interacting files, a long tool-call horizon, debugging where the fix is not obvious. Roughly twice the cost.

There is no cheap bulk lane by design. Work that would suit one is work you should do inline.

Claude's own fast lanes still apply for reading and summarizing — sonnet for exploration, haiku for lookups.

## Rules that survive contact

- Lanes exist only in claudemix sessions and are read at session start; a lane generated after a session began will not resolve in it.
- A lane's model comes from its agent-definition frontmatter. Inline `model` params cannot select gpt models.
- Each lane pins a default reasoning `effort` (`sol` xhigh, `terra` high) which becomes `reasoning.effort` upstream. In a Workflow you can override it per call — `agent(prompt, {agentType: 'terra', effort: 'low'})` — when a task needs a model's capability but not its depth. The Agent tool has no effort parameter, so there you get the lane default.
- **Bound the input, not the ambition.** Long multi-file builds are exactly what these lanes are for; what kills one is open-ended *reading*. A brief saying "read what you need" or "run the diff and review it" lets a lane read until it overruns its window, and the task then dies with `Prompt is too long` rather than degrading — you lose everything, with no partial result. Observed: four lanes given an open-ended review brief all died; the same review scoped to three named files with "read nothing else" ran fine in 24k tokens. Name the files, or hand over the excerpt yourself, then let the lane run as long as the job needs.
- Brief for completion: state the done-criteria and how to check them. A lane that knows what "finished" means will keep going; one that does not will hand back a plan.
- **Lanes do not compact.** Measured: a lane told to keep reading exhausted its context at ~128k tokens and stopped mid-file rather than summarising and continuing. So a single lane call is bounded work, not an unbounded session. For a job larger than that, stage it across several calls and carry state on disk between them — a `pipeline()` in a Workflow, or sequential Agent calls that each read the previous checkpoint. Tell the lane where to write its checkpoint; the generated prompts already tell it to keep one.
- Verify routing from the log, never from self-report: `grep cliproxy ~/.local/state/claudemix/splitter.log` shows `model=<lane> effort=<level> status=<code>` per request.
- Verify a lane's output like any subagent report — read the diff, run the checks. A lane will also confidently report an environmental block (a rate limit, a redirect) as a tool failure, so check its evidence rather than its verdict.
- On failure or degradation, fall back one step: terra → sol, sol → Claude opus. Say so in your report.
