#!/usr/bin/env python3
"""Vesta: keeps the vault consistent. Finds conflicts and stale items, never edits anything.

Three kinds of conflict, all checked by a plain read:
  - a registered project path that is missing
  - a [[link]] to a note that does not exist
  - an ORCID that differs between files

And one kind that is asked about, not decided: a TRACKER "Next session" item is shown
when it names a date that has already passed, or after it has stood unchanged for
STALE_AFTER days. The session asks whether it is still current. Vesta does not judge that.

Modes:
  scan             refresh the state (used at SessionEnd; prints nothing)
  brief            at SessionStart: refresh, then tell the session what is due
  resolve ID OK    accepted as intended (or still current), not asked again
  resolve ID FIX   keep it open; the session should help fix it
  list             print what is due

State lives in .pluto/vesta-state.json (gitignored). Each item has a stable id from its key,
so an accepted one stays accepted, a changed item is asked afresh, and a gone one drops out.
"""
import hashlib
import json
import re
import sys
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pluto_registry
from session_brief import parse_date

VAULT = Path(__file__).resolve().parents[2]
STATE = VAULT / ".pluto" / "vesta-state.json"
LINK = re.compile(r"\[\[([^\]|#]+)")
ORCID = re.compile(r"\b\d{4}-\d{4}-\d{4}-\d{3}[\dX]\b")
NOTE_DIRS = ["notes", "projects"]
STALE_AFTER = 14           # days an unchanged Next-session item may stand before it is asked
NEXT_HEADLINE = re.compile(r"^\d+\.\s+\*\*(.+?)\*\*", re.M)


def cid(key):
    return hashlib.sha1(key.encode()).hexdigest()[:8]


def note_files():
    for d in NOTE_DIRS:
        yield from sorted((VAULT / d).glob("*.md"))
    yield VAULT / "context.md"
    yield VAULT / "preferences.md"


def next_session_items(tracker):
    """Full headlines under a TRACKER 'Next session' heading, unshortened."""
    if not tracker.is_file():
        return []
    m = re.search(r"^##+ *Next session.*?$(.*)", tracker.read_text(errors="ignore"),
                  re.S | re.M)
    return NEXT_HEADLINE.findall(m.group(1)) if m else []


def found():
    """Every item currently visible, as (key, message, due_after_days)."""
    out = []
    today = date.today()

    for p in pluto_registry.projects():
        if p["path"] and not p["path"].is_dir():
            out.append((f"path:{p['name']}",
                        f"projects/{p['name']}.md: kayıtlı yol yok ({p['path']})", 0))
            continue
        if not p["path"]:
            continue
        for item in next_session_items(p["path"] / "TRACKER.md"):
            past = parse_date(item)
            if past and past < today:
                why = f"tarihi geçmiş ({past.isoformat()})"
                due = 0
            else:
                why = "bir süredir değişmedi"
                due = STALE_AFTER
            out.append((f"stale:{p['name']}:{item}",
                        f"{p['name']} · 'Next session': {item} ({why}). Hâlâ geçerli mi?", due))

    known = {f.stem for f in note_files()}
    for f in note_files():
        text = f.read_text(errors="ignore")
        for target in {t.strip() for t in LINK.findall(text)}:
            if target and target not in known:
                rel = f.relative_to(VAULT)
                out.append((f"link:{rel}->{target}", f"{rel}: [[{target}]] hedefi yok", 0))

    by_value = {}
    for f in note_files():
        for value in set(ORCID.findall(f.read_text(errors="ignore"))):
            by_value.setdefault(value, set()).add(str(f.relative_to(VAULT)))
    if len(by_value) > 1:
        detail = "; ".join(f"{v} → {', '.join(sorted(fs))}" for v, fs in by_value.items())
        out.append(("orcid:multiple", f"ORCID değerleri farklı: {detail}", 0))

    return out


def load_state():
    try:
        return json.loads(STATE.read_text())
    except (OSError, ValueError):
        return {}


def save_state(state):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(state, ensure_ascii=False, indent=2))


def scan():
    """Refresh the state. Keeps accepted decisions, drops items that no longer exist."""
    state = load_state()
    today = date.today().isoformat()
    current = {}
    for key, message, due in found():
        i = cid(key)
        entry = state.get(i, {"key": key, "first": today, "status": "open"})
        entry["message"] = message
        entry["due_after"] = due
        current[i] = entry
    save_state(current)
    return current


def age_days(entry):
    try:
        return (date.today() - date.fromisoformat(entry["first"])).days
    except (KeyError, ValueError):
        return 0


def due_items(state):
    """Open items whose time has come: not accepted, and old enough to ask about."""
    return [(i, e) for i, e in state.items()
            if e.get("status") != "ok" and age_days(e) >= e.get("due_after", 0)]


def brief():
    state = scan()
    items = due_items(state)
    if not items:
        return ""
    lines = ["## Vesta: oturum başında sorulacaklar"]
    for i, e in items[:6]:
        lines.append(f"- [{i}] {e['message']}")
    lines.append(
        "Bunları kullanıcıya kısa bir soru olarak sor. 'Doğru' ya da 'hâlâ geçerli' derse "
        "`python3 .claude/scripts/vesta.py resolve ID ok`, düzeltilecekse `... resolve ID fix` "
        "çalıştır. Notları ya da TRACKER'ları kendin düzeltme, yalnızca onayla.")
    lines.append(
        "Kullanıcı oturumu bitirirken sorulmamış bir madde varsa çıkmadan önce bir kez hatırlat.")
    return "\n".join(lines)


def resolve(i, verdict):
    state = load_state()
    if i not in state:
        print(f"bilinmeyen id: {i}", file=sys.stderr)
        return 1
    state[i]["status"] = "ok" if verdict == "ok" else "fix"
    save_state(state)
    print(f"{i}: {state[i]['status']}")
    return 0


def main(argv):
    mode = argv[1] if len(argv) > 1 else "brief"
    if mode == "scan":
        scan()
        return 0
    if mode == "brief":
        text = brief()
        if text:
            json.dump({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                              "additionalContext": text}}, sys.stdout)
            print()
        return 0
    if mode == "resolve" and len(argv) == 4 and argv[3].lower() in ("ok", "fix"):
        return resolve(argv[2], argv[3].lower())
    if mode == "list":
        for i, e in due_items(scan()):
            print(f"{i}  {e['message']}")
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
