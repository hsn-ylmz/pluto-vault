"""The project registry: `projects/*.md` front-matter, the one place the paths are right.

Both the session briefing and the indexer need it, and they need it from different
interpreters -- the briefing runs on system python3 inside a hook, the indexer on the venv
because it loads sqlite_vec. So this stays dependency-free on purpose.

It exists at all because the briefing hook used to carry its own hardcoded copy of the
list and spent an unknown stretch looking for a project in a directory that had moved.
"""
import re
from pathlib import Path

VAULT = Path(__file__).resolve().parents[2]


def projects():
    """One dict per registered project: name, path, and the first line under `## Status`.

    The status prose is for the caller to interpret, not to trust as current -- an old note still called a closed item its largest open item months after it closed.
    """
    out = []
    for f in sorted((VAULT / "projects").glob("*.md")):
        text = f.read_text(errors="ignore")
        fm = re.match(r"^---\n(.*?)\n---\n", text, re.S)
        if not fm:
            continue
        fields = dict(re.findall(r"^(\w+):\s*(.+)$", fm.group(1), re.M))
        raw = fields.get("path", "").strip()
        sm = re.search(r"^## Status\s*\n(.+)$", text, re.M)
        out.append({
            "name": fields.get("name", f.stem).strip(),
            "path": Path(raw).expanduser() if raw else None,
            "status": sm.group(1).strip() if sm else "",
            # Explicit only. Dates in the status prose are submission or start dates, not
            # deadlines; reading them as deadlines is what made the briefing say "expired".
            "deadline": fields.get("deadline", "").strip(),
        })
    return out


def is_active(project):
    return project["status"].lower().startswith("active")
