#!/bin/bash
# Wigbat installer — compiles the app, wires up Claude Code hooks, and
# installs a LaunchAgent so it auto-starts and auto-restarts on crash.
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$HOME/.claude/settings.json"
PLIST="$HOME/Library/LaunchAgents/com.wigbat.buddy.plist"

echo "==> Compiling Wigbat"
if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install Xcode Command Line Tools first:"
  echo "  xcode-select --install"
  exit 1
fi
(cd "$DIR/swift" && swiftc -O BuddyApp.swift -o buddy)

echo "==> Making scripts executable"
chmod +x "$DIR"/bin/*

echo "==> Writing LaunchAgent ($PLIST)"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.wigbat.buddy</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DIR/swift/buddy</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>$DIR/state/buddy.log</string>
    <key>StandardErrorPath</key>
    <string>$DIR/state/buddy.log</string>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST_EOF

echo "==> Wiring Claude Code hooks into $SETTINGS"
mkdir -p "$HOME/.claude"
if [ ! -f "$SETTINGS" ]; then
  echo '{}' > "$SETTINGS"
fi
cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d%H%M%S)"

SESSION_START_CMD="bash \"\$HOME/claude-awake-buddy/bin/hook-session-start.sh\" >/dev/null 2>&1 || true"
SESSION_END_CMD="bash \"\$HOME/claude-awake-buddy/bin/hook-session-end.sh\" >/dev/null 2>&1 || true"
NOTIFICATION_CMD="bash \"\$HOME/claude-awake-buddy/bin/hook-notification.sh\" >/dev/null 2>&1 || true"

jq --arg startCmd "$SESSION_START_CMD" \
   --arg endCmd "$SESSION_END_CMD" \
   --arg notifyCmd "$NOTIFICATION_CMD" '
  def already_has($type; $marker):
    ([(.hooks[$type] // [])[].hooks[]?.command] | any(contains($marker)));

  .hooks = (.hooks // {}) |
  (if already_has("SessionStart"; "hook-session-start.sh") then .
   else .hooks.SessionStart = ((.hooks.SessionStart // []) + [{
     hooks: [{type: "command", command: $startCmd, statusMessage: "Waking up the buddy..."}]
   }]) end) |
  (if already_has("SessionEnd"; "hook-session-end.sh") then .
   else .hooks.SessionEnd = ((.hooks.SessionEnd // []) + [{
     hooks: [{type: "command", command: $endCmd, statusMessage: "Letting the buddy sleep..."}]
   }]) end) |
  (if already_has("Notification"; "hook-notification.sh") then .
   else .hooks.Notification = ((.hooks.Notification // []) + [{
     hooks: [{type: "command", command: $notifyCmd, statusMessage: "Passing a note to the buddy..."}]
   }]) end)
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

echo "==> Starting Wigbat"
launchctl bootout "gui/$(id -u)/com.wigbat.buddy" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo ""
echo "Done. Wigbat is running and will auto-launch at login from now on."
echo "A backup of your previous settings.json was saved alongside it."
echo "Restart any open Claude Code sessions so the new hooks take effect."
