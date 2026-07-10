#!/bin/bash
# Called by the Claude Code "SessionEnd" hook.
# Decrements the session counter; only calls killawake once it hits 0,
# so one closed session doesn't stop keep-awake while others are still running.
DIR="$HOME/claude-awake-buddy/state"
mkdir -p "$DIR"
COUNT_FILE="$DIR/session-count"
LOCK="$DIR/.lock"

i=0
while ! mkdir "$LOCK" 2>/dev/null; do
  sleep 0.05
  i=$((i + 1))
  [ "$i" -gt 100 ] && break
done
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

count=$(cat "$COUNT_FILE" 2>/dev/null)
count=$(( ${count:-1} - 1 ))
[ "$count" -lt 0 ] && count=0
echo "$count" > "$COUNT_FILE"

if [ "$count" -eq 0 ]; then
  "$HOME/claude-awake-buddy/bin/killawake" >/dev/null
fi
