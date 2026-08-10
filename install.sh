#!/bin/sh
# One-shot, idempotent installer. Run it again any time; it converges.
#   1. Installs CLIProxyAPI (brew) and gives it a real local api key
#   2. Installs the splitter + verify script under ~/.claudemix
#   3. Supervises the splitter with launchd
#   4. Installs the claudemix shell command (launch / login / verify / status / log)
#   5. Writes the sol GPT subagent when a served gpt-* model is detectable
# After a fresh install the only manual step is: claudemix login && ./install.sh
set -eu

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="${CLAUDEMIX_CLIPROXY_CONF:-/opt/homebrew/etc/cliproxyapi.conf}"
PORT="${CLAUDEMIX_PORT:-8318}"
step() { printf '\n== %s\n' "$1"; }

step "prerequisites"
command -v node >/dev/null || { echo "node 18+ required"; exit 1; }
command -v claude >/dev/null || { echo "claude code required"; exit 1; }
command -v brew >/dev/null || { echo "homebrew required"; exit 1; }

step "cliproxyapi"
command -v cliproxyapi >/dev/null || brew install cliproxyapi
if [ -f "$CONF" ] && grep -q '"your-api-key-1"' "$CONF"; then
  KEY="sk-claudemix-$(openssl rand -hex 16)"
  python3 - "$KEY" "$CONF" <<'EOF'
import sys
key, conf = sys.argv[1], sys.argv[2]
s = open(conf).read()
block = 'api-keys:\n  - "your-api-key-1"\n  - "your-api-key-2"\n  - "your-api-key-3"\n'
if block in s:
    open(conf, 'w').write(s.replace(block, f'api-keys:\n  - "{key}"\n'))
    print("generated local api key")
EOF
  brew services restart cliproxyapi >/dev/null
else
  brew services list | grep -q "cliproxyapi.*started" || brew services start cliproxyapi >/dev/null
fi
sleep 1
curl -sf -o /dev/null --max-time 3 http://127.0.0.1:8317/ || { echo "cliproxyapi not answering on :8317"; exit 1; }
echo "cliproxyapi running"

step "splitter"
mkdir -p "$HOME/.claudemix"
cp "$REPO_DIR/claudemix-splitter.mjs" "$REPO_DIR/verify.sh" "$HOME/.claudemix/"
chmod +x "$HOME/.claudemix/claudemix-splitter.mjs" "$HOME/.claudemix/verify.sh"
sh "$REPO_DIR/install-launchd.sh"

step "shell command"
RC="$HOME/.zshrc"; case "${SHELL:-}" in */bash) RC="$HOME/.bashrc";; esac
python3 - "$RC" <<'EOF'
import sys, re, pathlib
rc = pathlib.Path(sys.argv[1]); text = rc.read_text() if rc.exists() else ""
begin, end = "# >>> claudemix >>>", "# <<< claudemix <<<"
block = begin + """
# Mixed-model Claude Code: main model = your Claude login through a local
# passthrough splitter; agents pinning a gpt-* model route to CLIProxyAPI.
# ENABLE_TOOL_SEARCH=true is required behind any ANTHROPIC_BASE_URL gateway.
claudemix() {
  case "${1:-}" in
    login)  cliproxyapi --config "${CLAUDEMIX_CLIPROXY_CONF:-/opt/homebrew/etc/cliproxyapi.conf}" --codex-login ;;
    verify) sh "$HOME/.claudemix/verify.sh" "${2:-}" ;;
    status) curl -s --max-time 3 "http://127.0.0.1:${CLAUDEMIX_PORT:-8318}/claudemix/status" | python3 -m json.tool ;;
    log)    tail -f "$HOME/.local/state/claudemix/splitter.log" ;;
    *)
      if ! curl -sf --max-time 1 -o /dev/null "http://127.0.0.1:${CLAUDEMIX_PORT:-8318}/claudemix/status" 2>/dev/null; then
        nohup node "$HOME/.claudemix/claudemix-splitter.mjs" >/dev/null 2>&1 &
      fi
      env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY -u CLAUDE_CODE_SUBAGENT_MODEL \
        ANTHROPIC_BASE_URL="http://127.0.0.1:${CLAUDEMIX_PORT:-8318}" \
        ENABLE_TOOL_SEARCH=true \
        claude "$@" ;;
  esac
}
""" + end
text = re.sub(re.escape(begin) + r".*?" + re.escape(end), "", text, flags=re.S)
text = re.sub(r"\n# claudemix: mixed-model Claude Code session\.[\s\S]*?\n}\n", "\n", text)
rc.write_text(text.rstrip() + "\n\n" + block + "\n")
print(f"claudemix command installed into {rc}")
EOF

step "sol agent"
SLUG="$(curl -s --max-time 3 "http://127.0.0.1:${PORT}/claudemix/status" | python3 -c 'import json,sys
import re
models = (json.load(sys.stdin).get("cliproxy") or {}).get("models") or []
def ver(m):
    n = re.match(r"gpt-(\d+)\.(\d+)", m)
    return (int(n.group(1)), int(n.group(2))) if n else (0, 0)
gpt = [m for m in models if m.startswith("gpt-") and not re.search(r"image|mini", m)]
gpt.sort(key=lambda m: (ver(m), m.endswith("-sol")), reverse=True)
print(gpt[0] if gpt else "")' 2>/dev/null || true)"
if [ -n "$SLUG" ]; then
  mkdir -p "$HOME/.claude/agents"
  cat > "$HOME/.claude/agents/sol.md" <<EOF
---
name: sol
description: GPT executor lane (works only inside a claudemix session, where the splitter routes gpt-* models to CLIProxyAPI). Use for delegated executor and writer tasks.
model: ${SLUG}
---

You are a delegated executor subagent. Perform exactly the task briefed, verify your work against the stated done criteria, and return a terse summary with evidence, never a dump. Do not re-plan the wider job or spawn further orchestration.
EOF
  echo "sol agent written with model ${SLUG}"
  echo ""
  echo "DONE. Open a new shell (or: source $RC), then run: claudemix verify"
else
  echo "no gpt-* model served yet (Codex login pending)"
  echo ""
  echo "NEXT: open a new shell (or: source $RC), then:"
  echo "  claudemix login      # browser sign-in to OpenAI/Codex"
  echo "  ./install.sh         # rerun; detects the model and writes the sol agent"
  echo "  claudemix verify"
fi
