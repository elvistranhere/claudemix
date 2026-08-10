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

| Lane | Model | For |
| --- | --- | --- |
| `sol` | gpt-5.6-sol | The hardest delegated work: complex multi-file implementation, long agentic tool sessions, thorny debugging |
| `terra` | gpt-5.6-terra | The default executor: routine implementation, refactors, tests, docs, at roughly half sol's cost |
| `luna` | gpt-5.6-luna | Bulk mechanical work: sweeps, renames, formatting, many small transforms |
| `spark` | gpt-5.3-codex-spark | Real-time short scope: single-file edits and quick reviews at 1,000+ tok/s |

Lanes whose model stops being served are removed on the next install rather than left to fail at delegation time, and `claudemix verify` fails if any installed lane points at an unserved model.

`models.md` is the rationale and the manual-override reference, including the models that get no standing lane (gpt-5.4 for ~1M-token context, gpt-5.4-mini for throwaway subagents). The `claudemix-routing` skill, installed to `~/.claude/skills/`, carries the decision procedure and the fallback ladder into every session.

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
- Logs contain routes, models, and status codes. Never headers or bodies.
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
- `install-launchd.sh` runs the splitter as a supervised launchd agent (starts at login, restarts on crash) instead of a one-shot nohup. It converges rather than restarting: a rerun that changes nothing leaves the running splitter alone, which matters because the session running the installer is proxying through that port. It also waits for `bootout` to finish before `bootstrap` (racing it returns `Bootstrap failed: 5: Input/output error`), hands the port over from any unmanaged splitter, and fails loudly if the launchd job is not the process actually holding the port. Without that last check the job can look loaded while supervising nothing, because the splitter exits 0 on `EADDRINUSE`.
- `verify.sh` extends the echo round-trip with tool-use, strict-JSON, count_tokens, and lane-integrity checks, all verified against the splitter log rather than model self-report.
- Agent lanes and the routing skill are generated from the served model list, so delegation is seamless instead of something you have to remember to configure.
- The log rotates at 10MB.

## License

MIT
