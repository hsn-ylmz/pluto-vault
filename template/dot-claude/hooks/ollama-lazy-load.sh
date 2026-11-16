#!/bin/bash
# Bring ollama up at SessionStart, because the MCP server needs it and cannot start it
# itself: pluto_index.py talks to /api/embed and only raises if nothing answers.
#
# Starting the daemon is all this does. No model is preloaded -- the first search_memory
# loads the embedding model (~270MB) on its own and keep_alive drops it again, whereas
# warming the chat model would cost 4.4GB on every session that never asks a question.
#
# `bin/pluto` runs its own ensure_ollama/stop_ollama pair around commands that need the
# model, so anything it starts, it stops. This hook deliberately does not stop anything:
# the session may still want search_memory. SessionEnd runs ollama-cleanup.sh.
set -u

OLLAMA_URL="${PLUTO_OLLAMA_URL:-http://localhost:11434}"
TIMEOUT=20   # half-seconds

is_running() {
  curl -fsS --connect-timeout 2 "$OLLAMA_URL/api/tags" > /dev/null 2>&1
}

is_running && exit 0

# Same method as bin/pluto-local.sh: the .app owns port 11434 once installed, and a bare
# `ollama serve` alongside it collides.
if [ "$(uname -s)" = "Darwin" ] && [ -d /Applications/Ollama.app ]; then
  open -ga Ollama > /dev/null 2>&1 || { echo "could not launch Ollama.app" >&2; exit 1; }
else
  (ollama serve > /tmp/ollama.log 2>&1 &)
fi

WAITED=0
while [ $WAITED -lt $TIMEOUT ]; do
  is_running && exit 0
  sleep 0.5
  WAITED=$((WAITED + 1))
done

echo "ollama did not come up within 10s" >&2
exit 1
