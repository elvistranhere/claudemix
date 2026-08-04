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

    // A pooled keep-alive socket can be closed server-side while idle; the next
    // write then fails (ECONNRESET/EPIPE) before any response bytes arrive. The
    // body is fully buffered, so one retry on a fresh socket is safe and
    // invisible to the client.
    const RETRYABLE = new Set(['ECONNRESET', 'EPIPE', 'ETIMEDOUT', 'ECONNREFUSED']);
    const send = (attempt) => {
      const upstream = toCliproxy
        ? http.request({ host: CLIPROXY_HOST, port: CLIPROXY_PORT, path: req.url, method: req.method, headers, agent: attempt === 1 ? cliproxyAgent : false })
        : https.request({ host: ANTHROPIC_HOST, port: 443, path: req.url, method: req.method, headers, agent: attempt === 1 ? anthropicAgent : false });
      upstream.setTimeout(0);
      upstream.on('response', (up) => {
        log(`${route} ${req.method} ${req.url} model=${model ?? '-'} status=${up.statusCode}${attempt > 1 ? ' (retry)' : ''}`);
        res.writeHead(up.statusCode, up.headers);
        up.pipe(res);
      });
      upstream.on('error', (err) => {
        const code = err.code || err.message;
        if (attempt === 1 && !res.headersSent && RETRYABLE.has(err.code)) {
          log(`RETRY ${route} ${req.method} ${req.url} ${code}`);
          send(2);
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
