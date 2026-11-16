#!/usr/bin/env python3
"""Write a daily-log entry from the day's commits, using the local model.

Commits, not the transcript. Three attempts at summarising the conversation all failed the
same way: the model answers from whatever is at the tail. Given only the discussion it
invented an implementation that had merely been proposed, complete with a verification line;
given a larger budget it echoed the debugging conversation back as the log. Commits cannot
be invented, they carry their own reasoning in the body, and 20 of them fit the context with
room to spare.

--with-transcript adds conversation for the "why". It is off by default because every
failure above came from it, and daily/ is injected into the next session by session-start.sh,
so an invention here becomes input.

Local only. This is deliberately not part of the published tool, whose design says hooks
never call a model — an argument about paid background spend that a local model answers,
and about summary quality, which it does not.
"""
import argparse, os, re, subprocess, sys
sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))
import pluto_llm
from datetime import date
from pathlib import Path

VAULT = Path(__file__).resolve().parents[2]

PROJECTS = Path.home() / ".claude" / "projects"

PROMPT = """You are writing one entry in an engineer's working log.

You are given the commits made today. Cover them, grouped by theme where they share one.

Write markdown in exactly this shape:

## <short topic, lowercase after the first word>
- <fact>
- <fact>

Rules:
- Facts only. What was decided, what changed, what is still open.
- No praise, no filler, no "we successfully". Never address the reader.
- Three to eight bullets. Wrap lines at about 95 characters.
- If something was tried and abandoned, say so and why.
- Output only the markdown. No preamble.

Hard constraints, because this file is read back into future sessions:
- State ONLY what the commits show. If you cannot point to one, leave it out.
- Take every number, file name and path from the commit text. Invent nothing.
- Never describe this log entry itself, where it is stored, or how it was produced.
- Never invent a file name, flag, command or number. Copy them from the input or omit them.
- Never claim something was verified, tested or measured unless the input says so.
- Work that was only discussed is not work that was done. Say "discussed" or "planned".
- Fewer, certain bullets beat more, plausible ones.

COMMITS:
{commits}
"""


def latest_transcript(slug_hint: str) -> Path | None:
    """The most recently modified transcript for a project directory."""
    if not PROJECTS.is_dir():
        return None
    cands = []
    for d in PROJECTS.iterdir():
        if slug_hint and slug_hint not in d.name:
            continue
        cands += list(d.glob("*.jsonl"))
    return max(cands, key=lambda p: p.stat().st_mtime) if cands else None


def conversation(path: Path, budget: int) -> str:
    """User prompts and assistant prose. Tool calls and results are dropped."""
    out = []
    for line in path.read_text(errors="ignore").splitlines():
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        msg = rec.get("message")
        if not isinstance(msg, dict):
            continue
        role = msg.get("role")
        if role not in ("user", "assistant"):
            continue
        content = msg.get("content")
        blocks = [content] if isinstance(content, str) else content or []
        for b in blocks:
            if isinstance(b, str):
                text = b
            elif isinstance(b, dict) and b.get("type") == "text":
                text = b.get("text", "")
            else:
                continue                      # tool_use, tool_result, thinking
            text = text.strip()
            if not text or text.startswith("<") or "system-reminder" in text[:200]:
                continue
            out.append(f"{role.upper()}: {text}")
    body = "\n\n".join(out)
    if len(body) > budget:                    # keep the end: that is where conclusions live
        body = "...\n\n" + body[-budget:]
    return body


def commits_today() -> str:
    """The day's commits from the vault and any sibling repo — facts the model cannot invent."""
    out = []
    for repo in (VAULT, Path.home() / "Documents" / "GitHub" / "pluto"):
        if not (repo / ".git").is_dir():
            continue
        try:
            r = subprocess.run(
                ["git", "-C", str(repo), "log", "--since=midnight", "--format=%h %s%n%b"],
                capture_output=True, text=True, timeout=20)
        except Exception:
            continue
        if r.stdout.strip():
            out.append(f"--- {repo.name} ---\n{r.stdout.strip()}")
    return "\n\n".join(out) or "(no commits today)"




def check(commits: str):
    """What a good entry looks like. Every failure here is one this tool actually produced."""
    known = set(re.findall(r"\b[0-9a-f]{7,40}\b", commits))

    def validate(answer: str):
        if "## " not in answer:
            return "no section heading"
        if not re.search(r"^\s*[-*] ", answer, re.M):
            return "no bullets"
        cited = set(re.findall(r"\b[0-9a-f]{7}\b", answer))
        invented = [h for h in cited if not any(k.startswith(h) for k in known)]
        if invented:
            return f"cites commits that do not exist: {', '.join(sorted(invented)[:3])}"
        if re.search(r"this log|this entry|sole source|was generated", answer, re.I):
            return "describes itself instead of the work"
        return None

    return validate


def main() -> int:
    ap = argparse.ArgumentParser(prog="pluto --log")
    ap.add_argument("--with-transcript", action="store_true",
                    help="also send the conversation (see the note at the top of this file)")
    ap.add_argument("--transcript", help="path to a .jsonl transcript")
    ap.add_argument("--budget", type=int, default=22000, help="chars of conversation to send")
    ap.add_argument("--print", action="store_true", help="print, do not append")
    args = ap.parse_args()

    commits = commits_today()
    if commits == "(no commits today)":
        print("no commits today — nothing to log", file=sys.stderr)
        return 1

    body = ""
    if args.with_transcript:
        path = Path(args.transcript) if args.transcript else latest_transcript(VAULT.name)
        if path and path.is_file():
            body = "\n\nTRANSCRIPT (context only, commits win where they disagree):\n" \
                   + conversation(path, args.budget)
            print(f"+ {path.name} ({len(body) // 1024} KB)", file=sys.stderr)
    print(f"{len(commits) // 1024} KB of commits", file=sys.stderr)

    prompt = PROMPT.format(commits=commits) + body
    entry, tier = pluto_llm.route(prompt, validate=check(commits),
                                  log=lambda m: print("  " + m, file=sys.stderr))
    print(f"written by {tier}", file=sys.stderr)
    entry = re.sub(r"^```(?:markdown)?\n|\n```$", "", entry).strip()

    if args.print:
        print(entry)
        return 0

    log = VAULT / "daily" / f"{date.today()}.md"
    log.parent.mkdir(exist_ok=True)
    if not log.exists():
        log.write_text(f"# {date.today()}\n\n")
    with log.open("a") as fh:
        fh.write("\n" + entry + "\n")
    print(f"appended to daily/{log.name}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
