#!/usr/bin/env python3
"""What is open across every active project, put in front of the session before it is asked.

Pull only helps when you already suspect something exists. This is the push side: the morning it answered "what is on my list" from one project alone, the others were a file away and nothing said so.

The registry is `projects/*.md` front-matter, which is the only place the paths are right;
the hook this replaces hardcoded them and pointed at a directory that has not existed for some time. Their prose goes stale too -- an old note still calls a closed item the largest open one -- so only name, path and the active/dead word are
read from there. Every status line comes from a live source: TRACKER.md and git.

Deterministic on purpose. File reads, git and local SQL, no model call and no network,
because this runs before every single session and must not be something worth skipping.
"""
import json
import re
import sqlite3
import subprocess
import sys
from datetime import date, datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pluto_registry

VAULT = Path(__file__).resolve().parents[2]
MAX_ITEMS = 3          # per project, from its tracker
HEADLINE = 58          # truncate a tracker headline to this

MONTHS = {m: i for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun",
     "jul", "aug", "sep", "oct", "nov", "dec"], 1)}
DATE_RE = re.compile(
    r"\b(\d{1,2})\s+([A-Za-z]{3,9})\.?\s+(\d{4})\b|\b(\d{4})-(\d{2})-(\d{2})\b")


def run(args, cwd=None):
    try:
        r = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=5)
        return r.stdout.strip() if r.returncode == 0 else ""
    except Exception:
        return ""


def parse_date(text):
    """The first date in the text, or None. Accepts '30 September 2026' and '2026-09-30'."""
    m = DATE_RE.search(text or "")
    if not m:
        return None
    try:
        if m.group(1):
            mon = MONTHS.get(m.group(2)[:3].lower())
            return date(int(m.group(3)), mon, int(m.group(1))) if mon else None
        return date(int(m.group(4)), int(m.group(5)), int(m.group(6)))
    except ValueError:
        return None


def tracker_items(root):
    """The headlines under a tracker's 'Next session' heading, most urgent first."""
    tracker = root / "TRACKER.md"
    if not tracker.is_file():
        return []
    text = tracker.read_text(errors="ignore")
    m = re.search(r"^##+ *Next session.*?$(.*)", text, re.S | re.M)
    if not m:
        return []
    items = re.findall(r"^\d+\.\s+\*\*(.+?)\*\*", m.group(1), re.M)
    out = []
    for it in items[:MAX_ITEMS]:
        it = re.split(r"\s+[-–—]\s+", it)[0].rstrip(".")
        out.append(it[:HEADLINE].rstrip() + ("…" if len(it) > HEADLINE else ""))
    return out


def git_line(root):
    if not (root / ".git").is_dir():
        return ""
    branch = run(["git", "branch", "--show-current"], cwd=root)
    dirty = run(["git", "status", "--porcelain"], cwd=root)
    n = len([x for x in dirty.splitlines() if x.strip()])
    if not branch:
        return ""
    return f"{branch}, {n} değişik" if n else f"{branch}, temiz"


def deadline_note(proj):
    """Days remaining, from an explicit `deadline: YYYY-MM-DD` in the project note only.

    Not read from the status prose or the tracker: "Submitted 2026-09-23" and "Started
    2026-09-29" are past events, and guessing a deadline from them announced a closed
    application as expired. A project with no deadline field shows no countdown.
    """
    d = parse_date(proj.get("deadline", ""))
    if not d:
        return ""
    left = (d - date.today()).days
    when = d.strftime("%d %b")
    if left < 0:
        return f"süresi {-left} gün önce doldu ({when})"
    if left == 0:
        return f"BUGÜN son gün ({when})"
    return f"{left} gün kaldı ({when})"



def still_open():
    """The newest daily that carries the section, which is not always the newest daily:
    today's entry may be a session log that never wrote one."""
    for f in sorted((VAULT / "daily").glob("*.md"), reverse=True)[:14]:
        m = re.search(r"^## Still open\s*\n(.*?)(?=^## |\Z)", f.read_text(errors="ignore"),
                      re.S | re.M)
        if not m:
            continue
        items = [l.lstrip("- ").strip()
                 for l in m.group(1).splitlines() if l.strip().startswith("-")]
        if items:
            return [(f.stem, i) for i in items]
    return []




def build():
    lines = [f"## Açık işler ({date.today().isoformat()})"]

    for p in pluto_registry.projects():
        if not pluto_registry.is_active(p):
            continue
        root, bits = p["path"], []
        if not root or not root.is_dir():
            lines.append(f"**{p['name']}** — ⚠ dizin yok: {root}")
            continue
        dl = deadline_note(p)
        if dl:
            bits.append(dl)
        g = git_line(root)
        if g:
            bits.append(g)
        items = tracker_items(root)
        # Nothing live to report: say what the project note says rather than a bare name.
        # No deadline is guessed from a file without a tracker -- JOB_SEARCH_STATUS.md
        # carries "27 Jul - 27 Sep" and a parser would announce the opening date.
        if not bits and not items:
            desc = re.sub(r"^\w+\s*[-–—]\s*", "", p["status"]).split(". ")[0]
            if desc:
                bits.append(desc[:70])
        lines.append(f"**{p['name']}**" + (f" — {'; '.join(bits)}" if bits else ""))
        for it in items:
            lines.append(f"  - {it}")


    opens = still_open()
    if opens:
        lines.append(f"Açık kalanlar ({opens[0][0]}):")
        for _, it in opens[:4]:
            lines.append(f"  - {it[:90]}")


    return "\n".join(lines)


def main():
    try:
        text = build()
    except Exception as e:
        text = f"## Açık işler\n(brifing üretilemedi: {type(e).__name__}: {e})"
    json.dump({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                      "additionalContext": text}}, sys.stdout)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
