#!/usr/bin/env python3
"""Prove the MCP server serves, not merely that it imports.

Speaks the handshake and reads until the tools/list answer arrives. An earlier version
piped three lines in with printf and grepped the output, which raced: printf closes stdin
immediately, and the server can shut down on EOF before it has answered. That failed
roughly one run in three. Holding stdin open and reading for a specific id removes the
race rather than hiding it behind a sleep.

Usage: mcp-smoke.py PYTHON VAULT     exit 0 if search_memory is advertised.
"""
import json
import signal
import subprocess
import sys

TIMEOUT = 30


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: mcp-smoke.py PYTHON VAULT", file=sys.stderr)
        return 2
    python, vault = sys.argv[1], sys.argv[2]

    # A wedged server must fail the check, not hang the installer.
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError()))
    signal.alarm(TIMEOUT)

    proc = subprocess.Popen(
        [python, f"{vault}/.claude/scripts/pluto_mcp.py"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )

    def send(msg):
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()

    def await_id(want):
        for line in proc.stdout:
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue          # servers may log non-JSON; skip rather than fail
            if msg.get("id") == want:
                return msg
        return None

    try:
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                         "clientInfo": {"name": "pluto-verify", "version": "1"}}})
        if await_id(1) is None:
            return 1
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        reply = await_id(2)
        if reply is None:
            return 1
        names = {t.get("name") for t in reply.get("result", {}).get("tools", [])}
        return 0 if "search_memory" in names else 1
    except (TimeoutError, BrokenPipeError):
        return 1
    finally:
        signal.alarm(0)
        proc.kill()
        proc.wait(timeout=5)


if __name__ == "__main__":
    sys.exit(main())
