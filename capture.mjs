// Request recorder. Two modes:
//   standalone  — returns a canned reply, nothing reaches a real upstream
//   pass-through — forwards to the splitter and records on the way (CLAUDEMIX_CAPTURE_FORWARD=1)
// The splitter never logs bodies, so this is the only way to check a claim
// about what Claude Code actually puts on the wire.
//
//   node capture.mjs &
//   printf 'hi' | env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY \
//     ANTHROPIC_BASE_URL=http://127.0.0.1:8399 claude -p --model gpt-5.6-terra
//   jq '.body | {model, thinking, output_config}' < /tmp/claudemix-capture.jsonl
import http from 'http';
import fs from 'fs';

const PORT = Number(process.env.CLAUDEMIX_CAPTURE_PORT || 8399);
const OUT = process.env.CLAUDEMIX_CAPTURE_FILE || '/tmp/claudemix-capture.jsonl';
const FORWARD = process.env.CLAUDEMIX_CAPTURE_FORWARD === '1';
const TARGET = Number(process.env.CLAUDEMIX_PORT || 8318);

const record = (url, raw) => {
  try {
    fs.appendFileSync(OUT, JSON.stringify({ at: new Date().toISOString(), url, body: JSON.parse(raw) }) + '\n');
  } catch {}
};

http
  .createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const body = Buffer.concat(chunks);
      const isCount = req.url.includes('count_tokens');
      if (req.url.includes('/v1/messages') && !isCount) record(req.url, body.toString('utf8'));

      if (FORWARD) {
        const headers = { ...req.headers, host: `127.0.0.1:${TARGET}`, 'content-length': String(body.length) };
        delete headers['transfer-encoding'];
        const up = http.request(
          { host: '127.0.0.1', port: TARGET, path: req.url, method: req.method, headers },
          (r) => {
            res.writeHead(r.statusCode, r.headers);
            r.pipe(res);
          },
        );
        up.on('error', (err) => {
          if (!res.headersSent) res.writeHead(502, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: { type: 'capture_forward', message: err.message } }));
        });
        up.end(body);
        return;
      }

      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(
        isCount
          ? JSON.stringify({ input_tokens: 10 })
          : JSON.stringify({
              id: 'msg_capture',
              type: 'message',
              role: 'assistant',
              model: 'capture',
              content: [{ type: 'text', text: 'ok' }],
              stop_reason: 'end_turn',
              usage: { input_tokens: 1, output_tokens: 1 },
            }),
      );
    });
  })
  .listen(PORT, '127.0.0.1', () =>
    console.log(`capture on 127.0.0.1:${PORT} -> ${OUT}${FORWARD ? ` (forwarding to :${TARGET})` : ''}`),
  );
