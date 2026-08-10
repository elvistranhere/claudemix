#!/bin/sh
# End-to-end verification battery. The repo's original check was an echo
# round-trip; real executor work needs tool use and strict output shapes, so
# those are tested here too. The splitter log is the only trusted evidence of
# which upstream served a request; model self-reports are never trusted.
#
# Usage: ./verify.sh [gpt-model-slug]   (default: first gpt-* model CLIProxyAPI serves)
set -u

PORT="${CLAUDEMIX_PORT:-8318}"
BASE="http://127.0.0.1:${PORT}"
LOG="$HOME/.local/state/claudemix/splitter.log"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $1${2:+  ($2)}"; }

run_claude() { # $1 extra args, $2 prompt (stdin: --allowedTools is variadic and would swallow a positional prompt)
  printf '%s' "$2" | env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY -u CLAUDE_CODE_SUBAGENT_MODEL \
    ANTHROPIC_BASE_URL="$BASE" ENABLE_TOOL_SEARCH=true \
    claude -p $1 2>/dev/null
}

# T1: splitter up + status endpoint
STATUS_JSON="$(curl -sf --max-time 3 "$BASE/claudemix/status" || true)"
echo "$STATUS_JSON" | grep -q '"ok":true' && ok "T1 splitter status endpoint" || bad "T1 splitter status endpoint" "is the splitter running?"

SLUG="${1:-$(echo "$STATUS_JSON" | grep -o '"gpt-[^"]*"' | head -1 | tr -d '"')}"
[ -n "${SLUG:-}" ] || { bad "T0 gpt model slug" "none passed and none found via /claudemix/status"; echo "RESULT: $PASS pass, $((FAIL)) fail"; exit 1; }
echo "using gpt slug: $SLUG"

# T2: Anthropic passthrough (own OAuth rides through)
OUT="$(run_claude "" "Reply with exactly: PASSTHROUGH-OK")"
echo "$OUT" | grep -q "PASSTHROUGH-OK" && ok "T2 claude passthrough" || bad "T2 claude passthrough" "$OUT"

# T3: gpt route, verified via splitter log not self-report
NONCE="mix-$(date +%s)"
OUT="$(run_claude "--model $SLUG" "Reply with exactly: $NONCE")"
# Match model and status without assuming they are adjacent: the log line grew an
# effort= field between them, and asserting on adjacency passed for a while purely
# on stale lines still inside the tail window.
if echo "$OUT" | grep -q "$NONCE" && tail -50 "$LOG" | grep "cliproxy" | grep -q "model=$SLUG .*status=200"; then
  ok "T3 gpt route (log-verified)"
else
  bad "T3 gpt route" "reply='$OUT'; check: grep cliproxy $LOG"
fi

# T4: tool use through the translation layer
OUT="$(run_claude "--model $SLUG --allowedTools Bash(echo:*)" "Run the bash command: echo TOOLS-OK and reply with only its output")"
echo "$OUT" | grep -q "TOOLS-OK" && ok "T4 gpt tool use" || bad "T4 gpt tool use" "$OUT"

# T5: strict output shape (proxy for structured-output reliability)
OUT="$(run_claude "--model $SLUG" 'Reply with exactly this JSON and nothing else: {"ok":true,"n":3}')"
echo "$OUT" | tr -d ' \n' | grep -q '{"ok":true,"n":3}' && ok "T5 gpt strict JSON" || bad "T5 gpt strict JSON" "$OUT"

# T6: count_tokens does not error through the gpt lane (native or estimated)
if tail -100 "$LOG" | grep "count_tokens" | grep -q "cliproxy"; then
  tail -100 "$LOG" | grep "count_tokens" | grep "cliproxy" | tail -1 | grep -Eq "status=2|count-tokens-estimated" \
    && ok "T6 count_tokens (native or estimated)" || bad "T6 count_tokens" "see log"
else
  echo "SKIP  T6 count_tokens (no such request observed this run)"
fi

# T7: every installed lane points at a model CLIProxyAPI actually serves.
# A lane whose model disappeared still looks like a valid agent type and fails
# only at delegation time, which is the worst place to find out.
LANES=0; STALE=""; NOEFFORT=""
for f in "$HOME"/.claude/agents/*.md; do
  [ -f "$f" ] || continue
  M="$(sed -n 's/^model: *//p' "$f" | head -1)"
  case "$M" in
    gpt-*) LANES=$((LANES+1))
           echo "$STATUS_JSON" | grep -q "\"$M\"" || STALE="$STALE $(basename "$f" .md)->$M"
           grep -q '^effort: ' "$f" || NOEFFORT="$NOEFFORT $(basename "$f" .md)" ;;
  esac
done
if [ "$LANES" -eq 0 ]; then
  echo "SKIP  T7 lane integrity (no gpt lanes installed; run ./install.sh)"
elif [ -n "$STALE" ]; then
  bad "T7 lane integrity" "unserved:$STALE"
else
  ok "T7 lane integrity ($LANES lanes)"
fi

# T8: every lane pins an effort. A lane without one inherits Claude Code's xhigh
# default, which CLIProxyAPI forwards as reasoning.effort=xhigh — the cheap lanes
# would then silently pay the most expensive reasoning tier.
if [ "$LANES" -eq 0 ]; then
  echo "SKIP  T8 lane effort (no gpt lanes installed)"
elif [ -n "$NOEFFORT" ]; then
  bad "T8 lane effort" "missing effort:$NOEFFORT (defaults to xhigh)"
else
  ok "T8 lane effort (all $LANES lanes pinned)"
fi

echo "RESULT: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
