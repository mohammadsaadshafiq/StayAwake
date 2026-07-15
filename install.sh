#!/bin/bash
# Wigbat installer — compiles the app, wires up Claude Code hooks, and
# installs a LaunchAgent so it auto-starts and auto-restarts on crash.
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$HOME/.claude/settings.json"
PLIST="$HOME/Library/LaunchAgents/com.wigbat.buddy.plist"

echo "==> Checking prerequisites"
# swiftc (from the Xcode Command Line Tools) is required to compile the app.
if ! command -v swiftc >/dev/null 2>&1; then
  echo "    ERROR: 'swiftc' not found — the Xcode Command Line Tools are required." >&2
  echo "    Install them, then re-run this script:" >&2
  echo "        xcode-select --install" >&2
  exit 1
fi
# jq is used for the Claude-hook merge and 'wigbat notify'; it falls back to
# python3, so warn rather than fail if neither is present.
if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  echo "    WARNING: neither 'jq' nor 'python3' found — Claude hook setup and" >&2
  echo "    'wigbat notify' may not work. Install jq with: brew install jq" >&2
fi
echo "    ok"

echo "==> Building Wigbat.app"
# Compiles the binary and installs Wigbat.app (Spotlight/Finder/Dock launchable,
# menu-bar-only while running). Prints the installed bundle path on its last line.
APP="$("$DIR/bin/make-app.sh")"
echo "    installed to $APP"

echo "==> Making scripts executable"
chmod +x "$DIR"/bin/*

echo "==> Installing the wigbat CLI"
if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
  BINDEST=/usr/local/bin
else
  BINDEST="$HOME/.local/bin"
  mkdir -p "$BINDEST"
fi
ln -sf "$DIR/bin/wigbat" "$BINDEST/wigbat"
echo "    linked wigbat -> $BINDEST/wigbat"
case ":$PATH:" in
  *":$BINDEST:"*) ;;
  *) echo "    NOTE: add $BINDEST to your PATH to run 'wigbat' from anywhere";;
esac

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
        <string>$APP/Contents/MacOS/buddy</string>
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

if [ -d "$HOME/.claude" ] || command -v claude >/dev/null 2>&1; then
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
else
  echo "==> Skipping Claude Code hooks (Claude Code not detected)"
  echo "    Wigbat still works via the menu app-watcher and the wigbat CLI."
fi

echo "==> Starting Wigbat"
launchctl bootout "gui/$(id -u)/com.wigbat.buddy" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo ""
echo "Done. Wigbat is running and will auto-launch at login from now on."
echo "A backup of your previous settings.json was saved alongside it."
echo "Restart any open Claude Code sessions so the new hooks take effect."
