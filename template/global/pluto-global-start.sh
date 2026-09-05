#!/bin/bash
# Inject preferences.md into every session, in every project. Read-only.
#
# Installed to ~/.claude/hooks/. This is the global layer: it makes the vault's preference
# file available everywhere without pulling any project content into the vault.
set -u
PLUTO="${PLUTO_HOME:-{{VAULT}}}"
P="$PLUTO/preferences.md"
[ -f "$P" ] || exit 0

# Don't double-inject when the session IS the vault; its own session-start hook handles that.
[ "${CLAUDE_PROJECT_DIR:-}" = "$PLUTO" ] && exit 0

CTX="$(cat "$P")"
ESC=$(printf '%s' "$CTX" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))') || exit 0
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$ESC"
exit 0
