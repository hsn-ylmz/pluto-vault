#!/bin/bash
# Every 20 prompts, remind that the session is worth logging.
set -u
S="$CLAUDE_PROJECT_DIR/.claude/hooks/.state"
mkdir -p "$S"
C=0; [ -f "$S/prompts" ] && C=$(cat "$S/prompts" 2>/dev/null || echo 0)
C=$((C + 1)); echo "$C" > "$S/prompts"
[ $((C % 20)) -eq 0 ] || exit 0
MSG="[pluto] $C messages. If this session produced a decision or an artifact, run /log before exiting."
ESC=$(printf '%s' "$MSG" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "$ESC"
exit 0
