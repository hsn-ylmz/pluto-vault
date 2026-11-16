#!/usr/bin/env python3
"""Index the vault and every registered project's prose into a local sqlite-vec table.

Embeddings via Ollama; nothing leaves the machine. The index lives under the vault even
though it holds text from other repositories: it is a derived, gitignored cache rather than content, so a question asked inside a project can still reach notes written in the vault.
"""
import sqlite3, sqlite_vec, urllib.request, json, hashlib, os, sys
from pathlib import Path

import pluto_registry

VAULT = Path(__file__).resolve().parents[2]
# Ollama is normally on this machine. PLUTO_OLLAMA_URL points it elsewhere — a container
# reaching the host, or a box on the LAN with the GPU in it.
OLLAMA = os.environ.get("PLUTO_OLLAMA_URL", "http://localhost:11434").rstrip("/")
DB = VAULT / ".pluto" / "index.db"
DIM = 768          # nomic-embed-text-v2-moe (verified at install: actual dim 768)
MODEL = "nomic-embed-text-v2-moe"
CHUNK, OVERLAP = 1000, 150   # model caps at 512 tokens; 1000 chars leaves headroom
SKIP = {".git", ".claude", ".pluto", ".obsidian", "archive", ".venv"}

# Regenerated from mail.db every day and heavily duplicated from one day to the next.
# They were 52 of 144 chunks, 93% of the jobs ones being tracking URLs, and they crowded
# real answers out of the top results: a search for a decision recorded in daily/ came
# back with two chunks of base64 above it. Query them through the DB or --report.
DERIVED = {"daily/jobs", "daily/mail", "daily/health"}

# Prose from every registered project, so "have we done this before" can be answered from
# outside the vault: a project's docs/ and .claude/rules/ are the
# literal record of what went wrong and how it was corrected. Every project is indexed,
# dead ones included -- the briefing is about attention and filters to active, this is
# about recall and a finished project is exactly the thing worth remembering.
#
# Source files are deliberately out of scope. The prose is where the question is actually
# answered, and 1.6 MB of code would be ten times this index for an embedding model
# trained on prose. Revisit with symbol-aware chunking, not by widening this glob.
PROJECT_GLOBS = ("*.md", "docs/**/*.md", ".claude/**/*.md")
BUILD_DIRS = {"node_modules", "target", ".venv", "venv", "build", "dist",
              "__pycache__", ".next", "vendor", "Pods", ".git", ".pluto"}

def embed(text: str, kind: str = "document"):
    # v2-moe is asymmetric: it REQUIRES these prefixes. Omitting them degrades retrieval.
    text = f"search_{kind}: {text}"
    for path, payload, key in (
        ("/api/embed", {"model": MODEL, "input": text}, "embeddings"),
        ("/api/embeddings", {"model": MODEL, "prompt": text}, "embedding"),
    ):
        try:
            req = urllib.request.Request(
                OLLAMA + path,
                data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json"},
            )
            out = json.loads(urllib.request.urlopen(req, timeout=60).read())[key]
            return out[0] if key == "embeddings" else out
        except Exception:
            continue
    raise RuntimeError(f"ollama embedding failed at {OLLAMA} — is `ollama serve` running?")

def chunks(text, size=CHUNK, overlap=OVERLAP):
    i = 0
    while i < len(text):
        yield text[i:i + size]
        i += size - overlap

def sources():
    """(display path, text) for everything indexed: the vault first, then project prose.

    Project paths are stored tilde-form and absolute, so a search hit says which repository
    it came from and can be opened without resolving it against the registry again.
    """
    for f in VAULT.rglob("*.md"):
        rel = f.relative_to(VAULT)
        if any(p in SKIP for p in rel.parts):
            continue
        if str(rel.parent) in DERIVED:
            continue
        yield str(rel), f.read_text(errors="ignore")

    home = str(Path.home())
    for proj in pluto_registry.projects():
        root = proj["path"]
        if not root or root == VAULT or not root.is_dir():
            continue
        for pattern in PROJECT_GLOBS:
            for f in sorted(root.glob(pattern)):
                if not f.is_file() or any(p in BUILD_DIRS for p in f.parts):
                    continue
                try:
                    yield str(f).replace(home, "~", 1), f.read_text(errors="ignore")
                except OSError:
                    continue


def main():
    DB.parent.mkdir(exist_ok=True)
    db = sqlite3.connect(DB)
    db.enable_load_extension(True); sqlite_vec.load(db); db.enable_load_extension(False)
    db.execute("CREATE TABLE IF NOT EXISTS chunks(id INTEGER PRIMARY KEY, path TEXT, sha TEXT, body TEXT)")
    db.execute(f"CREATE VIRTUAL TABLE IF NOT EXISTS vecs USING vec0(id INTEGER PRIMARY KEY, emb float[{DIM}] distance_metric=cosine)")

    # IF NOT EXISTS silently keeps an existing table, so a changed DIM, metric or
    # embedding model would append incomparable vectors to the old one. Fail loudly.
    want = f"emb float[{DIM}] distance_metric=cosine"
    got = db.execute("SELECT sql FROM sqlite_master WHERE name='vecs'").fetchone()[0]
    if want not in got:
        raise SystemExit(
            f"index schema mismatch\n  on disk: {got}\n  expected: {want}\n"
            f"Delete {DB} and reindex — vectors from a different model or metric "
            "are not comparable and will silently return nonsense."
        )

    seen, n = set(), 0
    for rel, text in sources():
        for c in chunks(text):
            sha = hashlib.sha256(c.encode()).hexdigest()
            seen.add(sha)
            if db.execute("SELECT 1 FROM chunks WHERE sha=?", (sha,)).fetchone():
                continue
            cur = db.execute("INSERT INTO chunks(path,sha,body) VALUES(?,?,?)", (rel, sha, c))
            db.execute("INSERT INTO vecs(id,emb) VALUES(?,?)",
                       (cur.lastrowid, json.dumps(embed(c))))
            n += 1
    # drop chunks whose source text no longer exists
    stale = [r[0] for r in db.execute("SELECT id FROM chunks").fetchall()
             if db.execute("SELECT sha FROM chunks WHERE id=?", (r[0],)).fetchone()[0] not in seen]
    for i in stale:
        db.execute("DELETE FROM chunks WHERE id=?", (i,))
        db.execute("DELETE FROM vecs WHERE id=?", (i,))
    db.commit()
    print(f"INDEX OK: +{n} new, -{len(stale)} stale")

if __name__ == "__main__":
    sys.exit(main())
