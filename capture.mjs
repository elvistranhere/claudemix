// Throwaway request recorder. Point ANTHROPIC_BASE_URL at it instead of the
// splitter to see the exact body Claude Code sends; the splitter never logs
// bodies, so this is the only way to check a claim about the wire format.
//   node capture.mjs &
//   printf 'hi' | env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY \
//     ANTHROPIC_BASE_URL=http://127.0.0.1:8399 claude -p --model gpt-5.6-terra
//   jq '{model, thinking, output_config}' < /tmp/claudemix-capture.jsonl
import http from 'http';
import fs from 'fs';

const PORT = Number(process.env.CLAUDEMIX_CAPTURE_PORT || 8399);
const OUT = process.env.CLAUDEMIX_CAPTURE_FILE || '/tmp/claudemix-capture.jsonl';

http
  .createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      const isCount = req.url.includes('count_tokens');
      if (req.url.includes('/v1/messages') && !isCount) {
        try {
          fs.appendFileSync(OUT, JSON.stringify({ url: req.url, body: JSON.parse(raw) }) + '\n');
        } catch {}
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
  .listen(PORT, '127.0.0.1', () => console.log(`capture on 127.0.0.1:${PORT} -> ${OUT}`));
