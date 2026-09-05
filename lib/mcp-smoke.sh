#!/bin/bash
# Speak enough JSON-RPC at the MCP server to prove it serves, not merely that it imports.
# Exits 0 if tools/list comes back naming search_memory.
#
# Usage: mcp-smoke.sh PYTHON VAULT
set -u
PY="${1:?python}"; VAULT="${2:?vault}"

printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"pluto-verify","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
| "$PY" "$VAULT/.claude/scripts/pluto_mcp.py" 2>/dev/null \
| grep -q '"name":"search_memory"'
