#!/bin/bash
# Inject context.md + rules.md + a pointer to the last daily log.
set -u
V="$CLAUDE_PROJECT_DIR"
S="$V/.claude/hooks/.state"
mkdir -p "$S"
date +%s > "$S/start"
echo 0 > "$S/prompts"

CTX=""
[ -f "$V/context.md" ] && CTX="$CTX$(cat "$V/context.md")

"
[ -f "$V/rules.md" ]   && CTX="$CTX$(cat "$V/rules.md")

"

LAST=$(ls -1 "$V/daily"/*.md 2>/dev/null | tail -1)
if [ -n "${LAST:-}" ]; then
  CTX="$CTX[last log: $(basename "$LAST")]
$(tail -20 "$LAST")
"
fi

[ -n "$CTX" ] || exit 0
ESC=$(printf '%s' "$CTX" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$ESC"
exit 0
