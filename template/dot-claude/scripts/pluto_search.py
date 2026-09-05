#!{{PY}}
import sqlite3, sqlite_vec, json, sys
from pathlib import Path
from pluto_index import embed, DB

def search(q, k=5):
    db = sqlite3.connect(DB)
    db.enable_load_extension(True); sqlite_vec.load(db); db.enable_load_extension(False)
    rows = db.execute(
        "SELECT c.path, c.body, v.distance FROM vecs v JOIN chunks c ON c.id = v.id "
        "WHERE v.emb MATCH ? AND k = ? ORDER BY v.distance",
        (json.dumps(embed(q, kind="query")), k),
    ).fetchall()
    return [{"path": p, "text": b, "score": round(1 - d, 3)} for p, b, d in rows]

if __name__ == "__main__":
    print(json.dumps(search(" ".join(sys.argv[1:])), indent=2))
