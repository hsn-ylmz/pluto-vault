#!/bin/bash
# Append raw tool events to .pluto/episodes.jsonl. Facts only, never conclusions.
#
# This is the episodic half of memory: what happened. The semantic half — what it meant —
# stays in notes/, written deliberately after reading these. A hook that inferred lessons
# would be the confabulation problem again, and this file feeds nothing automatically.
#
# Deliberately dumb and cheap: this runs after every single tool call. No python, no jq,
# no model, no parsing. It reads a bounded slice of stdin and appends it. Anything that
# costs more than a millisecond here is paid hundreds of times a session.
#
# The payload schema is not assumed. The first version records the raw event so the shape
# can be read from reality rather than guessed; the reader comes after there is data.
set -u
V="${CLAUDE_PROJECT_DIR:-$HOME/pluto}"
LOG="$V/.pluto/episodes.jsonl"

# Hard ceiling. An unbounded log on a hook this hot is how a vault quietly fills a disk.
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 5000000 ]; then
  exit 0
fi

mkdir -p "$V/.pluto" 2>/dev/null || exit 0
# head -c bounds a tool_response that might carry megabytes; tr strips the newlines that
# would otherwise break one-event-per-line.
printf '{"at":"%s","raw":"' "$(date -u +%FT%TZ)" >> "$LOG" 2>/dev/null
head -c 2000 | tr -d '\n\r' | sed 's/[\\"]/./g' >> "$LOG" 2>/dev/null
printf '"}\n' >> "$LOG" 2>/dev/null
exit 0
