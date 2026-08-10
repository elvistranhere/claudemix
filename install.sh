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

# Two lanes, both for long-horizon work, differing only in model cost. A cheap
# bulk lane and a real-time one existed here and were cut: work small enough for
# them is work not worth the round trip of delegating.
#
# Effort is one constant, not a per-lane dial. It rides frontmatter ->
# output_config.effort -> CLIProxyAPI reasoning.effort. xhigh is also Claude
# Code's own default, so this pins the value rather than changing it — stated
# explicitly so the lanes do not silently follow a default that later moves.
EFFORT = "xhigh"

lanes = [
    ("sol", "gpt-5.6-sol",
     "Default GPT executor lane. Long-horizon work of any difficulty: multi-file features, large refactors, migrations, thorny debugging. Give it a complete brief and let it run to completion. Works only inside a claudemix session.",
     "You are the default executor lane. The work you get is large and you are expected to finish it."),
    ("terra", "gpt-5.6-terra",
     "Same long-horizon executor work as sol at roughly half the cost, for tasks that are well specified rather than exploratory. Use it to conserve sol capacity, not because the task is small. Works only inside a claudemix session.",
     "You are the economical executor lane. The work you get is substantial and you are expected to finish it."),
]

body = """Perform exactly the task briefed, verify your work against the stated done criteria, and return a terse summary with evidence, never a dump. Do not re-plan the wider job or spawn further orchestration.

There is no Glob or Grep tool in this Claude Code build; Bash, Read, WebFetch, and WebSearch are available. Use Bash for file discovery and search (rg, find, ls) rather than reporting that you cannot look something up.

Long multi-step work is expected of you: implement, run it, fix what breaks, and keep going until the brief's done-criteria are actually met. Do not stop halfway, hand back a plan instead of the work, or ask permission to continue work you were already asked to do.

Budget your reading, not your effort. Your context does not compact: when it fills, the task stops where it stands, sometimes with no output at all. Treat it as a hard budget of roughly 100k tokens and spend it on the work rather than on exploration — read the files the brief names instead of surveying the tree, and scope commands that can emit a lot (diffs, logs, recursive listings) through rg or head.

Because of that, checkpoint as you go: keep progress on disk rather than in your head. Write what you changed, what you verified, and what remains, and update it as you work. Then if you do run out, the work survives and someone can resume it. If you can feel the budget running out before the job is done, stop deliberately, write the checkpoint, and report exactly where you got to and what the next step is — a clean handover is worth far more than another half-finished file."""

MARKER = "<!-- generated by claudemix install.sh; edits are overwritten -->"

agents_dir = os.path.expanduser("~/.claude/agents")
generated = set()

for name, model, description, opener in lanes:
    if model not in models:
        continue
    generated.add(name)
    with open(os.path.join(agents_dir, f"{name}.md"), "w") as f:
        f.write(f"---\nname: {name}\ndescription: {description}\nmodel: {model}\neffort: {EFFORT}\n---\n\n{opener} {body}\n\n{MARKER}\n")
    print(f"lane {name} -> {model} (effort {EFFORT})")

# Drop lanes this script generated previously that are no longer wanted, which is
# how retired lanes disappear. The marker is the whole safety story: a hand-written
# agent, even one pinned to a lane model, is never touched.
for fname in os.listdir(agents_dir):
    if not fname.endswith(".md") or fname[:-3] in generated:
        continue
    path = os.path.join(agents_dir, fname)
    try:
        text = open(path).read()
    except OSError:
        continue
    if MARKER in text:
        os.remove(path)
        print(f"lane {fname[:-3]} removed")

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
