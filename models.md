# Model lanes: what routes where, and why

Research snapshot 2026-08-10. The installer turns the served subset of these into agent lanes; this file is the rationale and the manual-override reference.

## GPT side (via CLIProxyAPI / Codex subscription)

| Model | Lane | Use for | Avoid for |
|---|---|---|---|
| gpt-5.6-sol | `sol` | The hardest autonomous work: complex multi-file coding, long agentic sessions with many tool calls, cybersecurity-grade analysis. Flagship; SOTA on BrowseComp (92.2%) and OSWorld 2.0, notably token-efficient for its tier. | High-volume trivial tasks (wasteful), real-time interactive loops |
| gpt-5.6-terra | `terra` | The default executor: routine implementation, refactors, test-writing, doc passes. GPT-5.5-level competence at roughly half the cost. | Frontier-difficulty reasoning, very long horizons |
| gpt-5.6-luna | `luna` | Bulk and speed: mechanical sweeps, formatting, simple transforms, high-volume small tasks. Near GPT-5.5 quality at a fraction of the cost, and the July 30 price cut made it 80% cheaper again. | Anything needing sustained multi-step judgment |
| gpt-5.3-codex-spark | `spark` | Real-time short-scope work: instant single-file edits, quick reviews, tight feedback loops. 1,000+ tok/s on Cerebras. | Long tasks (256K context, pair-programmer mode, not an autonomous agent) |
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
