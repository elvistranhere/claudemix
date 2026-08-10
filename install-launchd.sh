#!/bin/sh
# Installs the splitter as a supervised launchd agent (macOS): starts at login,
# restarts if it dies. Without this, the claudemix shell function's one-shot
# nohup start means a crashed splitter stays down until the next new session.
#
# Converges without restarting an already-correct service. That matters because
# a claudemix session proxies its own API traffic through this port, so a
# needless restart drops the connection of whoever is running the installer.
# Set CLAUDEMIX_FORCE_RESTART=1 to restart regardless.
set -eu

NODE_BIN="$(command -v node)"
SPLITTER="$HOME/.claudemix/claudemix-splitter.mjs"
PLIST="$HOME/Library/LaunchAgents/com.claudemix.splitter.plist"
LABEL="com.claudemix.splitter"
PORT="${CLAUDEMIX_PORT:-8318}"
DOMAIN="gui/$(id -u)"
STATUS_URL="http://127.0.0.1:${PORT}/claudemix/status"

[ -f "$SPLITTER" ] || { echo "splitter not found at $SPLITTER (run setup step 1 first)"; exit 1; }

healthy()      { curl -sf -o /dev/null --max-time 2 "$STATUS_URL"; }
loaded()       { launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }
job_pid()      { launchctl list 2>/dev/null | awk -v l="$LABEL" '$3==l && $1!="-" {print $1}'; }
port_pids()    { lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true; }

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST.new" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${NODE_BIN}</string>
    <string>${SPLITTER}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict>
    <key>Crashed</key><true/>
    <key>SuccessfulExit</key><false/>
  </dict>
  <key>StandardOutPath</key><string>/tmp/claudemix-splitter.out</string>
  <key>StandardErrorPath</key><string>/tmp/claudemix-splitter.err</string>
</dict>
</plist>
EOF

# Supervision is only real if the launchd job is the process holding the port.
# The splitter exits 0 on EADDRINUSE, so a job that deferred to an unmanaged
# nohup splitter looks loaded while supervising nothing.
JOB_PID="$(job_pid)"
if [ "${CLAUDEMIX_FORCE_RESTART:-0}" != "1" ] &&
   cmp -s "$PLIST.new" "$PLIST" 2>/dev/null &&
   loaded && [ -n "$JOB_PID" ] && [ "$(port_pids)" = "$JOB_PID" ] && healthy; then
  rm -f "$PLIST.new"
  echo "launchd agent already supervising a healthy splitter (pid $JOB_PID); left running"
  exit 0
fi

mv "$PLIST.new" "$PLIST"

case "${ANTHROPIC_BASE_URL:-}" in
  *":${PORT}"*) echo "note: restarting the splitter you are proxying through; a request may fail once" ;;
esac

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# bootout is asynchronous: bootstrapping before teardown finishes fails with
# "Bootstrap failed: 5: Input/output error".
i=0
while loaded && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done

# Hand the port over, or the new job hits EADDRINUSE and exits without supervising.
for pid in $(port_pids); do
  case "$(ps -o command= -p "$pid" 2>/dev/null)" in
    *claudemix-splitter*) kill "$pid" 2>/dev/null || true ;;
    *) echo "port $PORT is held by pid $pid, which is not a claudemix splitter; refusing to kill it"; exit 1 ;;
  esac
done
i=0
while [ -n "$(port_pids)" ] && [ "$i" -lt 25 ]; do sleep 0.2; i=$((i + 1)); done

i=0
until launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 5 ] || { echo "launchctl bootstrap failed 5 times"; launchctl bootstrap "$DOMAIN" "$PLIST"; exit 1; }
  sleep 0.5
done

i=0
while ! healthy && [ "$i" -lt 25 ]; do
  [ "$i" -eq 10 ] && launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null || true
  sleep 0.2; i=$((i + 1))
done

JOB_PID="$(job_pid)"
if ! healthy; then
  echo "agent installed but splitter not answering; check /tmp/claudemix-splitter.err"; exit 1
fi
if [ "$(port_pids)" != "$JOB_PID" ]; then
  echo "splitter is healthy but not the launchd job (port held by $(port_pids), job is ${JOB_PID:-none}); not supervised"; exit 1
fi
echo "launchd agent supervising splitter (pid $JOB_PID)"
