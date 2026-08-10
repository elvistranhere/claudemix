#!/bin/sh
# One-shot, idempotent installer. Run it again any time; it converges.
#   1. Installs CLIProxyAPI (brew) and gives it a real local api key
#   2. Installs the splitter + verify script under ~/.claudemix
#   3. Supervises the splitter with launchd
#   4. Installs the claudemix shell command (launch / login / verify / status / log)
#   5. Writes one agent lane per served gpt-* model, plus the routing skill
# After a fresh install the only manual step is: claudemix login && ./install.sh
# Reruns leave a healthy splitter running rather than restarting it.
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
FORCE_RESTART=0
cmp -s "$REPO_DIR/claudemix-splitter.mjs" "$HOME/.claudemix/claudemix-splitter.mjs" || FORCE_RESTART=1
cp "$REPO_DIR/claudemix-splitter.mjs" "$REPO_DIR/verify.sh" "$HOME/.claudemix/"
chmod +x "$HOME/.claudemix/claudemix-splitter.mjs" "$HOME/.claudemix/verify.sh"
CLAUDEMIX_FORCE_RESTART="$FORCE_RESTART" sh "$REPO_DIR/install-launchd.sh"

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

step "agent lanes + routing skill"
MODELS_JSON="$(curl -s --max-time 3 "http://127.0.0.1:${PORT}/claudemix/status" || true)"
mkdir -p "$HOME/.claude/agents" "$HOME/.claude/skills/claudemix-routing"
cp "$REPO_DIR/skills/claudemix-routing/SKILL.md" "$HOME/.claude/skills/claudemix-routing/SKILL.md"
python3 - "$MODELS_JSON" <<'EOF'
import json, os, sys

try:
    models = set((json.loads(sys.argv[1]).get("cliproxy") or {}).get("models") or [])
except Exception:
    models = set()

# effort rides frontmatter -> output_config.effort -> CLIProxyAPI reasoning.effort.
# Without it every lane inherits Claude Code's xhigh default, so the cheap lanes
# pay for the most expensive reasoning tier.
lanes = [
    ("sol", "gpt-5.6-sol", "xhigh",
     "Deep GPT executor lane for the hardest delegated work: complex multi-file implementation, long agentic tool sessions, thorny debugging execution. Works only inside a claudemix session.",
     "You are the deep executor lane for hard, well-briefed work."),
    ("terra", "gpt-5.6-terra", "medium",
     "Default GPT executor lane for routine implementation, refactors, test-writing, and doc passes at low cost. Prefer over sol when the task is well-specified and of moderate difficulty. Works only inside a claudemix session.",
     "You are the default executor lane for well-specified routine work."),
    ("luna", "gpt-5.6-luna", "low",
     "Fast cheap GPT lane for bulk mechanical work: sweeps, renames, formatting, high-volume small transforms. Not for multi-step judgment. Works only inside a claudemix session.",
     "You are the bulk lane. Each task you receive is small and mechanical; do exactly it."),
    ("spark", "gpt-5.3-codex-spark", "low",
     "Real-time GPT lane, 1000+ tokens per second with a small context: instant single-file edits and quick review passes with tiny scope. Not for long tasks. Works only inside a claudemix session.",
     "You are the real-time lane. Scope is tiny by design; if the task needs more than a few steps, say so and stop."),
]

body = """Perform exactly the task briefed, verify your work against the stated done criteria, and return a terse summary with evidence, never a dump. Do not re-plan the wider job or spawn further orchestration."""

agents_dir = os.path.expanduser("~/.claude/agents")
for name, model, effort, description, opener in lanes:
    path = os.path.join(agents_dir, f"{name}.md")
    if model in models:
        with open(path, "w") as f:
            f.write(f"---\nname: {name}\ndescription: {description}\nmodel: {model}\neffort: {effort}\n---\n\n{opener} {body}\n")
        print(f"lane {name} -> {model} (effort {effort})")
    elif os.path.exists(path) and f"model: {model}" in open(path).read():
        os.remove(path)
        print(f"lane {name} removed ({model} no longer served)")

if not models:
    print("no models served yet (Codex login pending); lanes unchanged")
EOF
if [ -z "$(curl -s --max-time 3 "http://127.0.0.1:${PORT}/claudemix/status" | grep -o 'gpt-')" ]; then
  echo ""
  echo "NEXT: open a new shell (or: source $RC), then:"
  echo "  claudemix login      # browser sign-in to OpenAI/Codex"
  echo "  ./install.sh         # rerun; detects models and writes the agent lanes"
  echo "  claudemix verify"
else
  echo ""
  echo "DONE. Open a new shell (or: source $RC), then: claudemix verify"
fi
