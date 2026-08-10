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
import { readFileSync, statSync, mkdirSync, appendFileSync, renameSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';

const PORT = Number(process.env.CLAUDEMIX_PORT || 8318);
const CLIPROXY_HOST = '127.0.0.1';
const CLIPROXY_PORT = Number(process.env.CLAUDEMIX_CLIPROXY_PORT || 8317);
const CLIPROXY_CONF = process.env.CLAUDEMIX_CLIPROXY_CONF || '/opt/homebrew/etc/cliproxyapi.conf';
const GPT_PREFIX = process.env.CLAUDEMIX_GPT_PREFIX || 'gpt-';
const ANTHROPIC_HOST = 'api.anthropic.com';
const STARTED_AT = Date.now();

const LOG_DIR = path.join(homedir(), '.local', 'state', 'claudemix');
mkdirSync(LOG_DIR, { recursive: true });
const LOG_FILE = path.join(LOG_DIR, 'splitter.log');
const LOG_ROTATE_BYTES = 10 * 1024 * 1024;
function log(line) {
  try {
    try { if (statSync(LOG_FILE).size > LOG_ROTATE_BYTES) renameSync(LOG_FILE, `${LOG_FILE}.1`); } catch {}
    appendFileSync(LOG_FILE, `${new Date().toISOString()} ${line}\n`);
  } catch {}
}

// CLIProxyAPI local API key, cached by config mtime. The key stays in memory only.
// Keys are read from the uncommented api-keys: block; the default brew config is
// full of commented-out sk-* doc examples that a bare regex would match first.
let keyCache = { mtimeMs: 0, key: null };
function proxyKey() {
  const { mtimeMs } = statSync(CLIPROXY_CONF);
  if (mtimeMs !== keyCache.mtimeMs) {
    const lines = readFileSync(CLIPROXY_CONF, 'utf8').split('\n').filter((l) => !/^\s*#/.test(l));
    const blockKeys = [];
    let inKeys = false;
    for (const line of lines) {
      if (/^api-keys:\s*$/.test(line)) { inKeys = true; continue; }
      if (inKeys) {
        const m = line.match(/^\s+-\s*"?([^"\s#]+)"?/);
        if (m) { blockKeys.push(m[1]); continue; }
        if (/^\S/.test(line)) inKeys = false;
      }
    }
    const usable = blockKeys.filter((k) => !/^your-api-key/.test(k));
    const key = usable.find((k) => k.startsWith('sk-')) ?? usable[0] ??
      (lines.join('\n').match(/\b(sk-[A-Za-z0-9._-]+)\b/) || [])[1] ?? null;
    if (!key) throw new Error('no usable key in cliproxyapi config api-keys block');
    keyCache = { mtimeMs, key };
  }
  return keyCache.key;
}

const anthropicAgent = new https.Agent({ keepAlive: true, maxSockets: 64 });
const cliproxyAgent = new http.Agent({ keepAlive: true, maxSockets: 64 });

// Local introspection endpoint, outside both upstream API namespaces.
function handleStatus(res) {
  const reply = (cliproxy) => {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({
      ok: true,
      port: PORT,
      uptime_s: Math.round((Date.now() - STARTED_AT) / 1000),
      gpt_prefix: GPT_PREFIX,
      log_file: LOG_FILE,
      cliproxy,
    }));
  };
  let key = null;
  try { key = proxyKey(); } catch (err) {
    reply({ reachable: false, error: err.message });
    return;
  }
  const probe = http.request(
    { host: CLIPROXY_HOST, port: CLIPROXY_PORT, path: '/v1/models', method: 'GET',
      headers: { authorization: `Bearer ${key}` }, timeout: 2000 },
    (up) => {
      const parts = [];
      up.on('data', (c) => parts.push(c));
      up.on('end', () => {
        let models = null;
        try { models = (JSON.parse(Buffer.concat(parts).toString('utf8')).data ?? []).map((m) => m.id); } catch {}
        reply({ reachable: true, status: up.statusCode, models });
      });
    },
  );
  probe.on('error', (err) => reply({ reachable: false, error: err.code || err.message }));
  probe.on('timeout', () => { probe.destroy(); reply({ reachable: false, error: 'timeout' }); });
  probe.end();
}

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/claudemix/status') {
    handleStatus(res);
    return;
  }
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('error', () => res.destroy());
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    let model = null;
    // Reasoning effort is the difference between a cheap lane and a flagship
    // bill, and it is invisible everywhere else: the client picks it, the proxy
    // translates it, neither logs it. Record it as metadata, never the body.
    let effort = null;
    if (body.length) {
      try {
        const parsed = JSON.parse(body.toString('utf8'));
        model = parsed.model ?? null;
        effort = parsed.output_config?.effort ?? null;
      } catch {}
    }
    const toCliproxy = typeof model === 'string' && model.startsWith(GPT_PREFIX);

    const headers = { ...req.headers };
    delete headers['transfer-encoding'];
    headers['content-length'] = String(body.length);

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
    } else {
      headers.host = ANTHROPIC_HOST;
    }
    const route = toCliproxy ? 'cliproxy' : 'anthropic';
    // Claude Code calls count_tokens on every model; CLIProxyAPI builds may not
    // implement it for translated backends. A failed count must degrade to an
    // estimate rather than surface as an API error inside the session.
    const countTokensFallback = toCliproxy && req.url.includes('/count_tokens');

    // A pooled keep-alive socket can be closed server-side while idle; the next
    // write then fails (ECONNRESET/EPIPE) before any response bytes arrive. The
    // body is fully buffered, so one retry on a fresh socket is safe and
    // invisible to the client.
    const RETRYABLE = new Set(['ECONNRESET', 'EPIPE', 'ETIMEDOUT', 'ECONNREFUSED']);
    // CLIProxyAPI answers 500/503 when the Codex upstream is overloaded, which several
    // concurrent agents reliably provoke. Passed through, that kills a long agent run
    // outright with no output. Retrying is safe only before any response byte reaches
    // the client and only on the gpt leg: Anthropic sends its own retry-after and
    // Claude Code already honours it, so retrying there would fight the client.
    const RETRYABLE_STATUS = new Set([429, 500, 502, 503, 504]);
    const MAX_ATTEMPTS = 3;
    const backoffMs = (attempt) => 400 * attempt * attempt;
    const send = (attempt) => {
      const upstream = toCliproxy
        ? http.request({ host: CLIPROXY_HOST, port: CLIPROXY_PORT, path: req.url, method: req.method, headers, agent: attempt === 1 ? cliproxyAgent : false })
        : https.request({ host: ANTHROPIC_HOST, port: 443, path: req.url, method: req.method, headers, agent: attempt === 1 ? anthropicAgent : false });
      upstream.setTimeout(0);
      upstream.on('response', (up) => {
        if (countTokensFallback && up.statusCode >= 400) {
          up.resume();
          const input_tokens = Math.max(1, Math.ceil(body.length / 4));
          log(`${route} ${req.method} ${req.url} model=${model ?? '-'} status=${up.statusCode} count-tokens-estimated=${input_tokens}`);
          res.writeHead(200, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ input_tokens }));
          return;
        }
        if (
          toCliproxy &&
          RETRYABLE_STATUS.has(up.statusCode) &&
          attempt < MAX_ATTEMPTS &&
          !res.headersSent
        ) {
          up.resume();
          const wait = backoffMs(attempt);
          log(`RETRY ${route} ${req.method} ${req.url} model=${model ?? '-'} status=${up.statusCode} in ${wait}ms`);
          setTimeout(() => send(attempt + 1), wait);
          return;
        }
        log(`${route} ${req.method} ${req.url} model=${model ?? '-'} effort=${effort ?? '-'} status=${up.statusCode}${attempt > 1 ? ` (attempt ${attempt})` : ''}`);
        res.writeHead(up.statusCode, up.headers);
        up.pipe(res);
      });
      upstream.on('error', (err) => {
        const code = err.code || err.message;
        if (attempt < MAX_ATTEMPTS && !res.headersSent && RETRYABLE.has(err.code)) {
          const wait = backoffMs(attempt);
          log(`RETRY ${route} ${req.method} ${req.url} ${code} in ${wait}ms`);
          setTimeout(() => send(attempt + 1), wait);
          return;
        }
        log(`ERROR ${route} ${req.method} ${req.url} ${code}`);
        if (!res.headersSent) {
          res.writeHead(502, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: { type: 'claudemix_splitter', message: `upstream error: ${code}` } }));
        } else {
          res.destroy();
        }
      });
      upstream.end(body);
    };
    send(1);
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
