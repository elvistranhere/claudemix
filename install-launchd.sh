#!/bin/sh
# Installs the splitter as a supervised launchd agent (macOS): starts at login,
# restarts if it dies. Without this, the claudemix shell function's one-shot
# nohup start means a crashed splitter stays down until the next new session.
set -eu

NODE_BIN="$(command -v node)"
SPLITTER="$HOME/.claudemix/claudemix-splitter.mjs"
PLIST="$HOME/Library/LaunchAgents/com.claudemix.splitter.plist"
LABEL="com.claudemix.splitter"

[ -f "$SPLITTER" ] || { echo "splitter not found at $SPLITTER (run setup step 1 first)"; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
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

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/${LABEL}"
sleep 1
curl -sf -o /dev/null --max-time 3 "http://127.0.0.1:${CLAUDEMIX_PORT:-8318}/claudemix/status" \
  && echo "launchd agent installed and splitter healthy" \
  || { echo "agent installed but splitter not answering; check /tmp/claudemix-splitter.err"; exit 1; }
