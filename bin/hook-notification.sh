#!/bin/bash
# Called by the Claude Code "Notification" hook. Reads the hook JSON from
# stdin and stashes the message so the widget can show it in a speech bubble.
DIR="$HOME/claude-awake-buddy/state"
mkdir -p "$DIR"

input=$(cat)
msg=$(echo "$input" | jq -r '.message // empty' 2>/dev/null)

if [ -n "$msg" ]; then
  jq -n --arg m "$msg" --argjson t "$(date +%s000)" '{message:$m, time:$t}' > "$DIR/message.json"
fi
