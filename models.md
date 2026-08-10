# Model lanes: what routes where, and why

Research snapshot 2026-08-10. The installer turns the served subset of these into agent lanes; this file is the rationale and the manual-override reference.

## GPT side (via CLIProxyAPI / Codex subscription)

| Model | Lane | Effort | Use for | Avoid for |
|---|---|---|---|---|
| gpt-5.6-terra | `terra` | `high` | The default executor: long-horizon implementation, refactors, test suites, migrations, at roughly half sol's cost. | Frontier-difficulty reasoning where the approach is not yet known |
| gpt-5.6-sol | `sol` | `xhigh` | The hardest autonomous work: many interacting files, long agentic sessions with many tool calls, non-obvious debugging. Flagship; SOTA on BrowseComp (92.2%) and OSWorld 2.0, notably token-efficient for its tier. | Work terra can do (twice the cost for no gain) |
| gpt-5.6-luna | manual | — | Bulk mechanical work at a fraction of the cost. **No standing lane**: work small enough to suit it is work not worth delegating, and the lane was another routing decision to get wrong. | Anything needing sustained multi-step judgment |
| gpt-5.3-codex-spark | manual | — | Real-time short-scope edits at 1,000+ tok/s on Cerebras. **No standing lane**, and a poor fit for this setup: no chain-of-thought phase at all, so reasoning config is silently ignored, and it is a pair-programmer rather than an autonomous agent. | Long tasks, which is all these lanes do |

### Why every lane pins an effort

Claude Code sends `thinking: {type: "adaptive"}` plus `output_config: {effort: "xhigh"}` on every request, including ones aimed at a model it does not recognize. CLIProxyAPI's Anthropic-to-Codex translator reads exactly those fields (`internal/translator/codex/claude/codex_claude_request.go`): on `adaptive` it takes `output_config.effort` verbatim, falling back to `xhigh` when absent, and writes it to `reasoning.effort`.

So a lane with no `effort` in its frontmatter runs GPT-5.6 at **xhigh** — the most expensive reasoning tier — no matter how cheap the model underneath is. That made `luna`, the lane chosen for bulk mechanical work, the most over-provisioned one in the set. Pinning effort per lane is what makes the cheap lanes actually cheap.

Verified on this machine by capturing the wire body Claude Code sends (see the README's verification note), not inferred from docs.

Related translator behavior worth knowing: `thinking: {type: "enabled", budget_tokens: N}` is bucketed to a level by `ConvertBudgetToLevel`, and `budget_tokens: 0` maps to `none`. A model-name suffix such as `gpt-5.6-terra(low)` is accepted by the proxy, but so is `gpt-5.6-terra(bogus)` — it returns 200 and silently ignores the level, so it is not a safe control surface.
| gpt-5.5 | manual | Broad strong generalist, the Codex default. Mostly dominated by terra on price and sol on capability; use when a lane misbehaves. | — |
| gpt-5.4 | manual | The long-context escape hatch: ~1M-token window for whole-repo or giant-log reads that exceed every other lane. | Ordinary tasks (terra is cheaper, sol is smarter) |
| gpt-5.4-mini | manual | Cheap micro-subagents. | Anything load-bearing |

## Claude side (your subscription, through the passthrough)

| Model | Use for |
|---|---|
| Fable 5 | Orchestration, planning, deep root-cause analysis, final review judgment. The main-loop model; delegate FROM it, not TO it. |
| Opus 5 | Hard writing and subtle code fixes where correctness under ambiguity matters; adversarial verification lanes. |
| Sonnet 5 | Reading, exploring, sweeping, summarizing; the fast balanced lane. |
| Haiku 4.5 | Trivial mechanical lookups at minimum cost. |

## Cross-family placement, honestly

- Frontier coding is contested: GPT-5.6 Sol leads several agentic benchmarks (OSWorld, BrowseComp) with far fewer output tokens, while Claude Opus-class models still lead SWE-Bench Pro. Treat sol and the Claude write-lane as peers; pick by workload shape, not tribalism.
- The GPT lanes run on the Codex subscription: effectively a separate budget pool. When Claude usage is the constraint, shifting executor volume to terra/luna is the point of claudemix.
- Structured-output fidelity through the translation layer is verified for sol (see verify.sh); assume the other lanes match but spot-check the splitter log on first use of each.

Sources: [OpenAI GPT-5.6 announcement](https://openai.com/index/gpt-5-6/), [OpenAI Sol preview](https://openai.com/index/previewing-gpt-5-6-sol/), [Vellum tier guide](https://www.vellum.ai/blog/gpt-5-6-sol-terra-luna-explained), [CodeRabbit benchmarks](https://www.coderabbit.ai/blog/gpt-5-6-sol-and-terra-benchmark), [GPT-5.3-Codex wiki](https://en.wikipedia.org/wiki/GPT-5.3-Codex), [Spark real-time coding](https://webscraft.org/blog/gpt53codexspark-realtime-koding-u-2026-scho-tse-i-navischo?lang=en), [NxCode model guide](https://www.nxcode.io/resources/news/openai-gpt-5-model-guide-which-to-use-2026), [Artificial Analysis 5.4 vs 5.3-Codex](https://artificialanalysis.ai/models/comparisons/gpt-5-4-vs-gpt-5-3-codex).
