#!/bin/bash
# Called by the Claude Code "SessionStart" hook.
# Increments a session counter; only calls stayawake when it goes 0 -> 1,
# so multiple concurrent Claude sessions don't step on each other.
DIR="$HOME/claude-awake-buddy/state"
mkdir -p "$DIR"
COUNT_FILE="$DIR/session-count"
LOCK="$DIR/.lock"

i=0
while ! mkdir "$LOCK" 2>/dev/null; do
  sleep 0.05
  i=$((i + 1))
  [ "$i" -gt 100 ] && break   # don't hang forever on a stale lock
done
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

count=$(cat "$COUNT_FILE" 2>/dev/null)
count=$(( ${count:-0} + 1 ))
echo "$count" > "$COUNT_FILE"

if [ "$count" -eq 1 ]; then
  "$HOME/claude-awake-buddy/bin/stayawake" >/dev/null
fi
