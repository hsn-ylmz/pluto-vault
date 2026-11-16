#!/bin/bash
# Inject preferences.md + context.md + rules.md + a pointer to the last daily log.
# preferences.md is injected here because the global pluto-global-start.sh skips the vault
# (to avoid double injection), so without this line the vault never sees the standing preferences.
set -u
V="$CLAUDE_PROJECT_DIR"
S="$V/.claude/hooks/.state"
mkdir -p "$S"
date +%s > "$S/start"
echo 0 > "$S/prompts"

CTX=""
[ -f "$V/preferences.md" ] && CTX="$CTX$(cat "$V/preferences.md")

"
[ -f "$V/context.md" ] && CTX="$CTX$(cat "$V/context.md")

"
[ -f "$V/rules.md" ]   && CTX="$CTX$(cat "$V/rules.md")

"

LAST=$(ls -1 "$V/daily"/*.md 2>/dev/null | tail -1)
if [ -n "${LAST:-}" ]; then
  CTX="${CTX}[last log: $(basename "$LAST")]
$(tail -20 "$LAST")
"
fi

[ -n "$CTX" ] || exit 0
ESC=$(printf '%s' "$CTX" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$ESC"
exit 0
