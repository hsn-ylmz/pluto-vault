#!/usr/bin/env python3
"""Route a prompt to the cheapest tier that can actually do it: local, then haiku, then opus.

Two checks, both mechanical, because "can the model handle this?" asked of the model itself
is answered yes every time.

  before spending   does the prompt fit the local context? Today's bug was that nothing
                    asked. Ollama takes an oversized prompt, silently truncates it, and
                    answers from the tail — which looks like a bad model rather than a
                    bad call.

  after answering   an optional validate(answer) supplied by the caller. It knows what a
                    good answer looks like for its own task; this module does not. If it
                    says no, the next tier gets the same prompt.

Escalation costs money, so every step says why it happened.
"""
import json
import os
import subprocess
import urllib.request

OLLAMA = os.environ.get("PLUTO_OLLAMA_URL", "http://localhost:11434").rstrip("/")
LOCAL_MODEL = os.environ.get("PLUTO_LOCAL_MODEL", "mistral:7b")


def model_available(model: str) -> bool:
    """Check if model is available on Ollama."""
    try:
        req = urllib.request.Request(OLLAMA + "/api/tags")
        with urllib.request.urlopen(req, timeout=5) as r:
            tags = json.loads(r.read()).get("models", [])
            return any(m["name"].split(":")[0] == model.split(":")[0] for m in tags)
    except Exception:
        return False

# Keep this value stable: ollama keys the resident model on num_ctx, and a
# different value evicts and reloads the weights.
LOCAL_CTX = 8192
ANSWER_ROOM = 1200          # tokens left for the reply, and for any reasoning the model does first
CHARS_PER_TOKEN = 4         # rough, deliberately pessimistic

DEFAULT_TIERS = ("local", "haiku", "opus")

# A prompt too big for the local model is exactly the prompt that costs real money on a
# paid one. Escalation must not turn "it did not fit" into a bill; anything past this is
# refused rather than sent, and the caller has to shrink it or opt in deliberately.
MAX_PAID_CHARS = 200_000


def fits_local(prompt: str) -> bool:
    return len(prompt) / CHARS_PER_TOKEN <= (LOCAL_CTX - ANSWER_ROOM)


def ask_local(prompt: str) -> str:
    req = urllib.request.Request(
        OLLAMA + "/api/chat",
        data=json.dumps({"model": LOCAL_MODEL, "stream": False,
                         "options": {"temperature": 0, "num_ctx": LOCAL_CTX},
                         "messages": [{"role": "user", "content": prompt}]}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=900) as r:
        return json.loads(r.read())["message"]["content"].strip()


def ask_claude(prompt: str, model: str) -> str:
    # stdin closed: claude -p waits on it otherwise and warns after three seconds.
    r = subprocess.run(["claude", "-p", "--model", model, prompt],
                       capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=900)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or "claude failed").strip()[:200])
    return r.stdout.strip()


def route(prompt, validate=None, tiers=DEFAULT_TIERS, log=None, allow_large=False):
    """Return (answer, tier). validate(answer) -> None if good, else a reason string."""
    say = log or (lambda m: None)
    last = None
    for tier in tiers:
        try:
            if tier == "local":
                if not fits_local(prompt):
                    say(f"local: skipped, {len(prompt) // 1024} KB will not fit {LOCAL_CTX} tokens")
                    continue
                if not model_available(LOCAL_MODEL):
                    say(f"local: skipped, {LOCAL_MODEL} not available on Ollama")
                    continue
                answer = ask_local(prompt)
            else:
                if len(prompt) > MAX_PAID_CHARS and not allow_large:
                    say(f"{tier}: refused, {len(prompt) // 1024} KB exceeds the paid-tier cap "
                        f"({MAX_PAID_CHARS // 1024} KB). Shrink it or pass allow_large=True.")
                    continue
                answer = ask_claude(prompt, tier)
        except Exception as e:
            say(f"{tier}: failed, {e}")
            continue

        if not answer:
            say(f"{tier}: empty answer")
            continue
        why = validate(answer) if validate else None
        if why:
            say(f"{tier}: rejected, {why}")
            last = answer
            continue
        say(f"{tier}: accepted")
        return answer, tier

    raise RuntimeError("no tier produced an acceptable answer" if last is None
                       else "every tier was rejected; last answer kept for inspection")
