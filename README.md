# claudemix

Run one Claude Code session that mixes models: a Claude model as the orchestrator, GPT subagents as executors. Your Claude subscription login is never proxied, stored, or re-signed; your OpenAI/Codex subscription powers the executor lanes.

```
Claude Code session
      |
      v
loopback splitter (127.0.0.1:8318, ~110 lines of Node you can read)
      |
      +-- model claude-* --> api.anthropic.com   (byte-for-byte passthrough, your own OAuth headers)
      +-- model gpt-*    --> CLIProxyAPI :8317   (your Codex OAuth, local API key)
```

## Why this shape

Claude Code's API endpoint is process-global, so per-agent routing needs a gateway in front. Existing mixed-model setups put the Claude subscription login inside the proxy too, which re-originates your Claude traffic under a spoofed client identity. This project does not do that: Anthropic-bound requests pass through untouched with the session's own credentials, which is the same base-URL gateway pattern Anthropic documents for enterprise LLM gateways. Only `gpt-*` requests are re-authed, with a local key, to a CLIProxyAPI instance that holds only your OpenAI/Codex OAuth.

## Quick start

```sh
git clone https://github.com/elvistranhere/claudemix && cd claudemix
./install.sh          # installs everything, idempotent
claudemix login       # one browser sign-in to OpenAI/Codex
./install.sh          # rerun: detects served models, writes the agent lanes
claudemix verify      # end-to-end battery incl. tool use, log-verified
```

`claudemix` then launches mixed-model sessions; `claudemix status` / `log` for introspection. SETUP.md remains as the manual/agent-driven path and documentation.

## Prerequisites

- Claude Code with a subscription (OAuth) login
- [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) on `127.0.0.1:8317` with a completed Codex login and a local `sk-*` API key in its config
- Node 18+

## Usage

```sh
claudemix                 # normal session, Claude main model
claudemix --dangerously-skip-permissions
```

Inside the session, delegate to GPT with a lane agent type (Agent tool `subagent_type: terra`, or `agentType: 'terra'` in Workflow scripts). The main model, and any subagent without a gpt model pinned, stays on Claude as normal.

## Model lanes

`install.sh` writes one agent lane per served model, so routing needs no configuration and no prompting. Claude Code picks a subagent by reading agent descriptions, so each lane's description states what it is good at and the orchestrator routes to it on its own.

| Lane | Model | Effort | For |
| --- | --- | --- | --- |
| `terra` | gpt-5.6-terra | `high` | The default executor. Long-horizon work with a complete brief: features, refactors, test suites, migrations |
| `sol` | gpt-5.6-sol | `xhigh` | Work that is genuinely hard: many interacting files, long tool-call horizons, non-obvious debugging. Roughly twice the cost |

Both lanes are sized for **long-horizon execution** — give one a complete brief and let it run to completion. A cheap bulk lane and a real-time lane existed here and were removed: work small enough to suit them is work not worth the round trip of delegating, and every extra lane is another routing decision to get wrong.

The pinned effort is not cosmetic. Claude Code sends `output_config: {effort: "xhigh"}` by default on every request, including ones aimed at a model it does not recognize, and CLIProxyAPI's translator forwards that straight into `reasoning.effort`. A lane without an explicit effort runs at the most expensive tier whatever model is underneath it. `claudemix verify` fails if a lane is missing one.

It is a default, not a ceiling: in a Workflow, override it per call with `agent(prompt, {agentType: 'terra', effort: 'low'})`. The Agent tool has no effort parameter, so there you get the lane default.

Lanes whose model stops being served are removed on the next install rather than left to fail at delegation time. Generated lanes carry a marker comment and cleanup only removes files that have it, so a hand-written agent — even one pinned to a lane model — is never touched by an install run.

`models.md` is the rationale and the manual-override reference, including models that get no standing lane. The `claudemix-routing` skill, installed to `~/.claude/skills/`, carries the decision procedure into every session.

## The three gotchas that matter

1. **Route subagents via agent definitions, not the inline model param.** A `model: gpt-...` line in `~/.claude/agents/sol.md` frontmatter works; passing the same string inline in an Agent tool call is silently rejected and falls back to a Claude model.
2. **Verify with the log, never with the model's self-report.** Subagents will claim to be whatever the prompt implies. `~/.local/state/claudemix/splitter.log` records which upstream actually served every request.
3. **Force tool search back on.** Behind any `ANTHROPIC_BASE_URL` gateway, Claude Code silently disables tool-schema deferral and inlines every MCP tool schema. On a tool-heavy machine that added over 100k tokens of boot context (measured: 164k vs 41k), which pegs the context meter from the first turn and can produce instant client-side "Prompt is too long" errors. The `claudemix` shell function sets `ENABLE_TOOL_SEARCH=true`, which restores deferral through the gateway. Do not reach for `CLAUDE_CODE_AUTO_COMPACT_WINDOW` instead; it clamps the effective limit downward and makes things worse.

Also: leave `CLAUDE_CODE_SUBAGENT_MODEL` unset in these sessions, or every subagent gets flattened onto one model.

## Performance

Measured against direct connections: overhead is within noise. The splitter keeps warm keep-alive TLS pools to both upstreams, responses stream straight through (time-to-first-token unaffected), request-side work is one JSON parse to read the model field. Roughly 40MB of resident memory while running; it starts on demand from the shell function.

Reliability: idle keep-alive sockets that the upstream closed are retried once on a fresh connection (connection-level failures only, before any response bytes), so stale-pool resets never surface to the client as 502s.

## Security notes

- Binds `127.0.0.1` only. Do not expose it.
- Stores nothing: Anthropic credentials are forwarded as received; the CLIProxyAPI key is read from your existing config at request time and kept in memory only.
- Logs contain routes, models, reasoning effort, and status codes. Never headers or bodies.
- Your Anthropic account's traffic remains an unmodified Claude Code client behind a base-URL gateway. The GPT side is your own OpenAI subscription through CLIProxyAPI, an arrangement OpenAI has publicly been permissive about. Read both providers' terms and make your own call; this is infrastructure, not legal advice.

## Configuration

| Env var | Default | Meaning |
| --- | --- | --- |
| `CLAUDEMIX_PORT` | `8318` | Splitter listen port |
| `CLAUDEMIX_CLIPROXY_PORT` | `8317` | CLIProxyAPI port |
| `CLAUDEMIX_CLIPROXY_CONF` | `/opt/homebrew/etc/cliproxyapi.conf` | Where to read the `sk-*` key |
| `CLAUDEMIX_GPT_PREFIX` | `gpt-` | Model prefix routed to CLIProxyAPI |

## Hardening in this fork

- `proxyKey()` parses the uncommented `api-keys:` block instead of grabbing the first `sk-*` string in the file. The stock brew config ships with five commented-out `sk-*` doc examples and placeholder keys, which the upstream regex happily matched, yielding 401s on a fresh install.
- `count_tokens` on the gpt lane degrades to a local estimate when CLIProxyAPI does not implement it, instead of surfacing an API error inside the session.
- `GET /claudemix/status` reports uptime, config, CLIProxyAPI reachability, and the model list it serves.
- `install-launchd.sh` supervises the splitter with launchd (starts at login, restarts on crash) instead of a one-shot nohup, and **converges rather than restarts** — a rerun that changes nothing leaves the running splitter alone, which matters because the session running the installer is proxying through that port. Three failure modes it now handles: `bootout` is async so bootstrapping immediately after returns `Bootstrap failed: 5: Input/output error`; an unmanaged splitter already holding the port must be handed over; and the job can look loaded while supervising nothing, because the splitter exits 0 on `EADDRINUSE`.
- `verify.sh` extends the echo round-trip with tool-use, strict-JSON, count_tokens, lane-integrity, and lane-effort checks, all asserted against the splitter log rather than model self-report.
- Agent lanes and the routing skill are generated from the served model list, each pinning a reasoning effort (see Model lanes above), so delegation needs no configuration.
- Transient upstream failures on the gpt leg are retried rather than passed through. CLIProxyAPI answers 500/503 when the Codex upstream is overloaded, which concurrent agents reliably provoke, and a passed-through 503 kills a long agent run outright with no output. Up to 3 attempts with quadratic backoff, only before any response byte has reached the client. Deliberately **not** applied to the Anthropic leg: it sends its own `retry-after` and Claude Code already honours it, so retrying there would fight the client.
- The log records reasoning effort per request and rotates at 10MB.

## Field notes

Things established by measurement here, kept because each one cost time to find and would otherwise be re-litigated.

### Verifying what actually goes on the wire

Claims about which fields reach the upstream are worth checking rather than trusting, and the splitter deliberately never logs headers or bodies. To capture a real request, point Claude Code at a throwaway HTTP server instead of the splitter and read the body it posts:

```sh
# minimal capture server on :8399 that logs the body and returns a canned reply
node capture.mjs &
printf 'hi' | env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY \
  ANTHROPIC_BASE_URL=http://127.0.0.1:8399 claude -p --model gpt-5.6-terra
```

That is how the `output_config.effort` default above was established. Note `timeout` is not present on stock macOS, so leave it out of probe scripts or the command silently never runs.

### What tools work in a lane

Audited by having each lane test its own tool access. All four agreed: Bash, Read, WebFetch, and WebSearch work; Glob and Grep are not present.

**The missing tools are not a claudemix effect.** Capturing the `tools` array Claude Code actually sends shows Glob and Grep absent from a plain session too, with the gateway and tool search both switched off. This Claude Code build does not ship them, so a lane is exactly as capable as the orchestrator driving it. The lane prompts point at Bash (`rg`, `find`) for discovery because that is how search works here generally, not to paper over a translation-layer gap.

Web access working is the finding that matters: a lane can search and read sources on the Codex budget rather than the Claude one, which is what makes research fan-out worth delegating at all.

The same capture answers the tool-search question quantitatively — `ENABLE_TOOL_SEARCH=true` yields **12 tools** in the request against **122** without it.

Worth knowing when you read a lane's self-report: an earlier audit marked WebSearch "failed" on evidence that was actually an account rate-limit message. A lane will confidently report an environmental block as a tool failure, so check the evidence, not the verdict.

### Context windows: leave the default alone

Claude Code does not recognize `gpt-*` model ids, so it assumes a 200K window per lane and auto-compacts against that. The obvious fix is the `[1m]` model-name suffix Claude Code itself suggests, and it does work through this stack — Claude Code strips the suffix client-side, so the splitter sees a plain `gpt-5.6-terra` and the request routes normally.

Do it anyway and you would probably regret it. The raw API window for the 5.6 tier is about 1.05M tokens, but these lanes run on a **Codex** credential, and the Codex surface caps the same models far lower — [reported at ~372K with a 95% effective multiplier](https://github.com/openai/codex/issues/32486), so roughly 353K usable. Telling Claude Code it has 1M would let a session grow past what the backend accepts and fail mid-task instead of compacting. The same report notes Codex sessions crossing **272K move into a higher-usage pricing band**, which on a personal Codex subscription is your bill, not a rounding error.

So 200K is close to the right number for this path, not a shortfall to work around. Spark's 256K is the only lane meaningfully under-served, and being conservative there costs nothing.

Sources: [Codex context metadata issue](https://github.com/openai/codex/issues/32486), [GPT-5.6 Sol specifications](https://gate.ai/blog/gpt-5-6-sol-openai-specs-pricing-api-access-use-cases), [GPT-5.6 limits guide](https://www.layer3labs.io/guides/gpt-5-6-limits)

### Lanes do not compact, so stage long work

Claude Code's unknown-model warning says auto-compact will keep a session within the 200K window it assumes. That is not what a lane does. Measured: a lane instructed to keep reading 80KB files exhausted its context at **~128k tokens**, stopped mid-file, and reported how far it got — it did not summarise and continue. Other times the same wall arrives as a hard `Prompt is too long` with no output at all.

Two consequences for long-horizon work, which is what these lanes are for:

- **A lane call is bounded work, not an unbounded session.** For a job bigger than roughly 100k tokens of reading, stage it across several calls with state on disk between them — a `pipeline()` in a Workflow, or sequential Agent calls that each pick up the previous checkpoint.
- **Checkpointing is what makes a long run survivable.** The generated lane prompts tell each lane to keep progress on disk and, if the budget runs out, to stop deliberately and hand over cleanly rather than dying mid-edit.

`Read` caps a single call at 25k tokens, so one oversized file cannot blow the window on its own — the risk is accumulation across many reads, not any single one.

### Brief lanes with bounded input

A lane that is told to "read what you need" will read until it overruns its window, and the task then dies with `Prompt is too long` rather than degrading — you lose the work and get no partial result. Four lanes given an open-ended review brief all died this way; the same review, scoped to three named files with "read nothing else", ran fine in 24k tokens.

The constraint is on *input*, not on task length. Long multi-step builds are what the deep lane is for, and the generated prompts tell each lane to keep working until the done-criteria are met and to persist progress to disk so a long run does not depend on holding everything in context. What does not work is surveying a tree or piping an unbounded diff into the window. Name the files, or hand over the excerpt yourself, then let the lane run as long as the job needs.

## License

MIT
