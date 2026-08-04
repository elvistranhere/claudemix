# claudemix agent setup

Paste this entire file into a coding agent (Claude Code, etc.) running on the target machine. Agent: follow the steps in order, verify each one, and report what you did. Everything is idempotent; re-running is safe.

## What you are building

A loopback "splitter" proxy on `127.0.0.1:8318` that lets one Claude Code session mix models: the main model stays a Claude model (your normal Anthropic subscription login, forwarded untouched), while subagents can run on a GPT model through a locally installed CLIProxyAPI instance holding the user's own OpenAI/Codex OAuth. No credentials are stored by the splitter, and the user's Anthropic credentials never enter CLIProxyAPI.

## Step 0: check prerequisites

Verify each; if one fails, stop and tell the user what to install:

1. `node --version` is v18 or newer.
2. `claude --version` works and the user is logged in with a Claude subscription (OAuth), not an API key.
3. CLIProxyAPI is installed and running on `127.0.0.1:8317` (commonly `brew install cliproxyapi` then `brew services start cliproxyapi`). Check: `curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8317/` returns any HTTP code (connection refused = not running).
4. Its config file (default `/opt/homebrew/etc/cliproxyapi.conf`) contains an `sk-...` local API key, and the user has completed a Codex login (`cliproxyapi --config <conf> --codex-login`, which needs the user present for a browser flow). If the config lives elsewhere, export `CLAUDEMIX_CLIPROXY_CONF` accordingly in step 2.
5. Confirm which `gpt-*` model slug the user's CLIProxyAPI serves (ask the user or check its docs/config). Use it in step 3; this document uses `gpt-5.6-sol` as the example.

## Step 1: install the splitter

Write the following file to `~/.claudemix/claudemix-splitter.mjs` (create the directory). If this repository is available locally or via URL, copy `claudemix-splitter.mjs` from it instead; the content is identical.

```js
#!/usr/bin/env node
// claudemix splitter: a loopback model-router for mixed-model Claude Code sessions.
//
// Anthropic-bound requests (claude-* models, and anything without a model field)
// are forwarded to api.anthropic.com BYTE-FOR-BYTE with the client's own headers.
// This process never reads, stores, or re-signs your Anthropic credentials; it is
// a plain pass-through, the same shape as the LLM gateway pattern documented by
// Anthropic for enterprise use.
//
// Requests whose body model matches the GPT prefix (default "gpt-") are re-authed
// with your CLIProxyAPI local key and sent to the loopback CLIProxyAPI instance,
// which holds your OpenAI/Codex OAuth. Your Anthropic subscription credentials
// never enter CLIProxyAPI.
//
// Binds 127.0.0.1 only. Logs route/model/status lines only, never headers or
// bodies. The log is the ground truth for which model actually served a request.

import http from 'node:http';
import https from 'node:https';
import { readFileSync, statSync, mkdirSync, appendFileSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';

const PORT = Number(process.env.CLAUDEMIX_PORT || 8318);
const CLIPROXY_HOST = '127.0.0.1';
const CLIPROXY_PORT = Number(process.env.CLAUDEMIX_CLIPROXY_PORT || 8317);
const CLIPROXY_CONF = process.env.CLAUDEMIX_CLIPROXY_CONF || '/opt/homebrew/etc/cliproxyapi.conf';
const GPT_PREFIX = process.env.CLAUDEMIX_GPT_PREFIX || 'gpt-';
const ANTHROPIC_HOST = 'api.anthropic.com';

const LOG_DIR = path.join(homedir(), '.local', 'state', 'claudemix');
mkdirSync(LOG_DIR, { recursive: true });
const LOG_FILE = path.join(LOG_DIR, 'splitter.log');
function log(line) {
  try { appendFileSync(LOG_FILE, `${new Date().toISOString()} ${line}\n`); } catch {}
}

// CLIProxyAPI local API key, cached by config mtime. The key stays in memory only.
let keyCache = { mtimeMs: 0, key: null };
function proxyKey() {
  const { mtimeMs } = statSync(CLIPROXY_CONF);
  if (mtimeMs !== keyCache.mtimeMs) {
    const match = readFileSync(CLIPROXY_CONF, 'utf8').match(/\b(sk-[A-Za-z0-9._-]+)\b/);
    if (!match) throw new Error('no sk-* api key found in cliproxyapi config');
    keyCache = { mtimeMs, key: match[1] };
  }
  return keyCache.key;
}

const anthropicAgent = new https.Agent({ keepAlive: true, maxSockets: 64 });
const cliproxyAgent = new http.Agent({ keepAlive: true, maxSockets: 64 });

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('error', () => res.destroy());
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    let model = null;
    if (body.length) {
      try { model = JSON.parse(body.toString('utf8')).model ?? null; } catch {}
    }
    const toCliproxy = typeof model === 'string' && model.startsWith(GPT_PREFIX);

    const headers = { ...req.headers };
    delete headers['transfer-encoding'];
    headers['content-length'] = String(body.length);

    let upstream;
    if (toCliproxy) {
      let key;
      try { key = proxyKey(); } catch (err) {
        log(`ERROR cliproxy-key ${err.message}`);
        res.writeHead(502, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: { type: 'claudemix_splitter', message: `CLIProxyAPI key unavailable: ${err.message}` } }));
        return;
      }
      headers.host = `${CLIPROXY_HOST}:${CLIPROXY_PORT}`;
      headers.authorization = `Bearer ${key}`;
      delete headers['x-api-key'];
      upstream = http.request({
        host: CLIPROXY_HOST, port: CLIPROXY_PORT, path: req.url,
        method: req.method, headers, agent: cliproxyAgent,
      });
    } else {
      headers.host = ANTHROPIC_HOST;
      upstream = https.request({
        host: ANTHROPIC_HOST, port: 443, path: req.url,
        method: req.method, headers, agent: anthropicAgent,
      });
    }

    upstream.setTimeout(0);
    upstream.on('response', (up) => {
      log(`${toCliproxy ? 'cliproxy' : 'anthropic'} ${req.method} ${req.url} model=${model ?? '-'} status=${up.statusCode}`);
      res.writeHead(up.statusCode, up.headers);
      up.pipe(res);
    });
    upstream.on('error', (err) => {
      log(`ERROR ${toCliproxy ? 'cliproxy' : 'anthropic'} ${req.method} ${req.url} ${err.code || err.message}`);
      if (!res.headersSent) {
        res.writeHead(502, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: { type: 'claudemix_splitter', message: `upstream error: ${err.code || err.message}` } }));
      } else {
        res.destroy();
      }
    });
    upstream.end(body);
  });
});

server.headersTimeout = 120000;
server.requestTimeout = 0;
server.keepAliveTimeout = 75000;
server.listen(PORT, '127.0.0.1', () => {
  log(`claudemix splitter listening on 127.0.0.1:${PORT} (anthropic passthrough + ${GPT_PREFIX}* -> cliproxy:${CLIPROXY_PORT})`);
  console.log(`claudemix splitter on 127.0.0.1:${PORT}`);
});
server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.log(`port ${PORT} already in use, assuming a splitter is running`);
    process.exit(0);
  }
  console.error(err.message);
  process.exit(1);
});
```

## Step 2: add the shell function

Detect the user's shell (`$SHELL`). Append the block below to `~/.zshrc` (zsh) or `~/.bashrc` (bash), only if a `claudemix` function is not already defined there. For bash, replace the zsh-only `&!` with `& disown`.

```sh
# claudemix: mixed-model Claude Code session. Main model = your normal Claude
# login, forwarded untouched by a local splitter (:8318); subagents whose agent
# definition pins a gpt-* model are routed to CLIProxyAPI (:8317).
# CLAUDE_CODE_SUBAGENT_MODEL must stay unset or it flattens per-agent routing.
claudemix() {
  if ! curl -sf --max-time 1 -o /dev/null http://127.0.0.1:8318/api/hello 2>/dev/null; then
    nohup node "$HOME/.claudemix/claudemix-splitter.mjs" >/dev/null 2>&1 &!
    sleep 0.5
  fi
  env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY -u CLAUDE_CODE_SUBAGENT_MODEL \
    ANTHROPIC_BASE_URL="http://127.0.0.1:8318" \
    claude "$@"
}
```

## Step 3: create the GPT subagent

Write `~/.claude/agents/sol.md` (create the directory if needed). Replace `gpt-5.6-sol` with the model slug from step 0.5 if different:

```markdown
---
name: sol
description: GPT executor lane (works only inside a claudemix session, where the splitter routes gpt-* models to CLIProxyAPI). Use for delegated executor and writer tasks.
model: gpt-5.6-sol
---

You are a delegated executor subagent. Perform exactly the task briefed, verify your work against the stated done criteria, and return a terse summary with evidence, never a dump. Do not re-plan the wider job or spawn further orchestration.
```

Important: the agent definition's `model:` frontmatter is the ONLY reliable way to route a subagent to a gpt model. Passing `model` inline in an Agent tool call silently falls back to a Claude model in current Claude Code builds.

## Step 4: verify (do not skip)

Never trust a model's claim about its own identity; subagents will happily hallucinate "I am GPT" if the prompt implies it. The splitter log at `~/.local/state/claudemix/splitter.log` is the only ground truth.

1. Start the splitter: `node ~/.claudemix/claudemix-splitter.mjs &` then `curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8318/api/hello` must print `200` (that 200 comes from api.anthropic.com through the passthrough).
2. Claude passthrough: run `env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY ANTHROPIC_BASE_URL="http://127.0.0.1:8318" claude -p "Reply with exactly: PASSTHROUGH-OK"` and expect that reply. Confirms OAuth rides through with only the base URL overridden.
3. GPT route: same command with `--model gpt-5.6-sol` (or the user's slug). Then `grep cliproxy ~/.local/state/claudemix/splitter.log` must show a `model=gpt-... status=200` line.
4. Mixed session: `claudemix -p "Spawn ONE Agent with subagent_type sol. Its prompt: run the bash command echo mix-ok and return only its output. Return the agent reply."` Then check the log again: the sol agent's requests must appear as `cliproxy ... model=gpt-...` lines with status 200. If they appear as `anthropic ... model=claude-...`, the agent definition was not picked up (wrong path or wrong frontmatter).
5. Report the relevant log lines to the user as evidence.

## Troubleshooting

- 401 on the gpt route: CLIProxyAPI's Codex OAuth expired; re-run its codex login.
- 502 with "CLIProxyAPI key unavailable": config path wrong; set `CLAUDEMIX_CLIPROXY_CONF`.
- Splitter port busy: a splitter is already running (duplicate spawns exit cleanly).
- All subagents suddenly one model: `CLAUDE_CODE_SUBAGENT_MODEL` leaked into the environment; it must be unset.
