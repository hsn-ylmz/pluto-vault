#!/bin/bash
# Refresh the semantic index so search_memory sees what earlier sessions wrote.
#
# It had not run once in fourteen days, because reindex existed only as an MCP tool that
# nothing ever called: every search answered from a 6 Sept snapshot of the vault while 50
# files had changed since. pluto_index.main() keys chunks by sha, so a repeat run embeds
# only what actually changed and costs almost nothing.
#
# Backgrounded, because session start must not wait on it, and the index is for the next
# question rather than this instant.
set -u

VAULT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
PY="$VAULT/.venv/bin/python"
OLLAMA_URL="${PLUTO_OLLAMA_URL:-http://localhost:11434}"

[ -x "$PY" ] || exit 0

(
  # ollama-lazy-load is a sibling hook, so the daemon may still be binding.
  for _ in $(seq 30); do
    curl -fsS --connect-timeout 1 "$OLLAMA_URL/api/tags" > /dev/null 2>&1 && break
    sleep 1
  done
  "$PY" "$VAULT/.claude/scripts/pluto_index.py" >> "$VAULT/.pluto/index.log" 2>&1
) &

exit 0
