#!{{PY}}
"""Index the vault into a local sqlite-vec table. Embeddings via Ollama. Nothing leaves the machine."""
import sqlite3, sqlite_vec, urllib.request, json, hashlib, os, sys
from pathlib import Path

VAULT = Path(__file__).resolve().parents[2]
# Ollama is normally on this machine. PLUTO_OLLAMA_URL points it elsewhere — a container
# reaching the host, or a box on the LAN with the GPU in it.
OLLAMA = os.environ.get("PLUTO_OLLAMA_URL", "http://localhost:11434").rstrip("/")
DB = VAULT / ".pluto" / "index.db"
DIM = 768          # nomic-embed-text-v2-moe (verified at install: actual dim 768)
MODEL = "nomic-embed-text-v2-moe"
CHUNK, OVERLAP = 1000, 150   # model caps at 512 tokens; 1000 chars leaves headroom
SKIP = {".git", ".claude", ".pluto", ".obsidian", "archive", ".venv"}

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
    for f in VAULT.rglob("*.md"):
        if any(p in SKIP for p in f.relative_to(VAULT).parts):
            continue
        rel, text = str(f.relative_to(VAULT)), f.read_text(errors="ignore")
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
