#!/bin/bash
# Before compaction, nudge for a real write-up while the detail still exists.
set -u
MSG="[pluto] Context is about to compact. Write anything durable from this session to notes/ or daily/ now."
ESC=$(printf '%s' "$MSG" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
printf '{"hookSpecificOutput":{"hookEventName":"PreCompact","additionalContext":%s}}\n' "$ESC"
exit 0
