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

## Quick start (agent setup)

Paste the raw contents of [SETUP.md](SETUP.md) into Claude Code (or any capable coding agent) on your machine and let it do the whole thing: install the splitter, add the `claudemix` shell function, create the GPT subagent, and run the verification tests.

Manual setup is the same four steps; SETUP.md doubles as the documentation.

## Prerequisites

- Claude Code with a subscription (OAuth) login
- [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) on `127.0.0.1:8317` with a completed Codex login and a local `sk-*` API key in its config
- Node 18+

## Usage

```sh
claudemix                 # normal session, Claude main model
claudemix --dangerously-skip-permissions
```

Inside the session, delegate to GPT with the `sol` agent type (Agent tool `subagent_type: sol`, or `agentType: 'sol'` in Workflow scripts). The main model, and any subagent without a gpt model pinned, stays on Claude as normal.

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

## License

MIT
