#!/bin/bash
# Stop Ollama and free every resident model. Runs at SessionEnd; safe to run by hand.
#
# Graceful first, the same way bin/pluto-local.sh's stop_ollama does it: quitting the app
# makes it tear down its own `ollama serve` and `llama-server` children, so no orphan
# window ever opens. pkill is only for what ignores the quit.
#
# Order matters for the fallback. The app respawns `ollama serve`, and `ollama serve`
# owns one `llama-server` child per loaded model. Kill the parent on its own and the
# children are reparented to launchd, where nothing honours keep_alive and the model
# stays resident until reboot -- that is how nomic-embed-text sat in RAM on 20 Sept.
#
# No launchctl here on purpose: `com.ollama.ollama` is a Background Task Management
# login item pointing at the app's Squirrel updater, not at the server. It cannot be
# stopped from launchctl (errno 5), and stopping it would not free a model anyway.
set -u

# -x matches the executable name exactly, so nothing else on the machine can be caught.
TARGETS=(Ollama ollama llama-server)

if pgrep -x Ollama > /dev/null 2>&1; then
  osascript -e 'quit app "Ollama"' > /dev/null 2>&1 || true
  sleep 2
fi

for name in "${TARGETS[@]}"; do
  pgrep -x "$name" > /dev/null 2>&1 && pkill -x "$name" 2>/dev/null
done
sleep 1

for name in "${TARGETS[@]}"; do
  pgrep -x "$name" > /dev/null 2>&1 && pkill -9 -x "$name" 2>/dev/null
done
sleep 1

left=""
for name in "${TARGETS[@]}"; do
  pids=$(pgrep -x "$name" | tr '\n' ' ')
  [ -n "$pids" ] && left="$left $name($pids)"
done

if [ -n "$left" ]; then
  echo "ollama-cleanup: still running:$left" >&2
  exit 1
fi

exit 0
