#!/bin/bash
# Append a factual stub. No model call. No summary invented by a hook.
set -u
V="$CLAUDE_PROJECT_DIR"
S="$V/.claude/hooks/.state"
LOG="$V/daily/$(date +%F).md"
START=0; [ -f "$S/start" ]   && START=$(cat "$S/start"   2>/dev/null || echo 0)
P=0;     [ -f "$S/prompts" ] && P=$(cat "$S/prompts" 2>/dev/null || echo 0)
NOW=$(date +%s)
MIN=$(( (NOW - START) / 60 ))

# Only log sessions that were actually sessions.
if [ "$P" -ge 3 ]; then
  mkdir -p "$V/daily"
  [ -f "$LOG" ] || printf '# %s\n\n' "$(date +%F)" > "$LOG"
  printf -- '- session %s — %s min, %s prompts\n' "$(date +%H:%M)" "$MIN" "$P" >> "$LOG"
fi
rm -f "$S/start" "$S/prompts"
exit 0
