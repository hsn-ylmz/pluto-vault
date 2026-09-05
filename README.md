# pluto

Persistent memory for a coding agent, made of plain markdown files you own.

Your agent starts every session knowing nothing. Pluto is a directory of notes plus four
hooks that put the right ones in front of it — who you are, what you are working on, and the
corrections you already made once. Everything is a file you can read, edit in any editor, and
put in git. There is no database of record and no service.

```
pluto                                     pick a project, open it
pluto api-server                           open that one
pluto api-server why does the test fail    open it, seeded with the question
pluto how can I clean my mac safely?      just ask, from anywhere
pluto --status                            what moved since you last looked
```

**This is a reference implementation, not a framework.** It was extracted from a vault that is
in daily use, and it is published because the design is worth copying, not because it wants to
become your dependency. Fork it and change it; that is the intended use.

## Install

```bash
git clone https://github.com/<you>/pluto.git
cd pluto
./install.sh
```

The installer asks before it does anything and prints what it would do with `--dry-run`. It is
safe to re-run: **code** (`bin/`, `.claude/`) is brought up to date every time, **content**
(`context.md`, `rules.md`, `projects/`, `notes/`, `daily/`) is created once and never touched
again. That is how you upgrade.

```bash
./install.sh --dry-run                    # show everything, write nothing
./install.sh --vault ~/second-brain       # somewhere else
./install.sh --no-semantic --no-global    # core only, nothing outside the vault
./install.sh --semantic                   # add local search to an existing vault later
```

## What you get

| Tier | Gives you | Cost |
|---|---|---|
| **core** | vault, git, session hooks, the `pluto` launcher, `/log` | none — always installed |
| **semantic** | local embeddings, `search_memory` over everything, MCP server | Ollama + a ~1 GB model |
| **global** | `preferences.md` injected into *every* project, `/pref` | writes to `~/.claude` |
| **cloud** | private git remote, age-encrypted offsite bundle | your own remote |

Declining everything still leaves a working vault. The heavy tier is asked for last and can be
added later.

## Adding a project

```bash
pluto --create api-server --path ~/code/api-server --status "the thing that serves the API"
pluto --create                 # or answer three prompts
```

It becomes a usable CLI argument immediately — `pluto api-server` resolves it and TAB
completion offers it on the next keystroke. Nothing is cached and nothing is regenerated,
because the completions read `pluto --names`, which reads `projects/*.md`. Completion for
zsh and bash is installed and wired into your rc file.

The flags exist so project creation can be scripted; with `--path` given it needs no
terminal at all. Creating a missing directory is never silent — you are asked, or you passed
`--mkdir`.

## Agents

Claude Code gets the whole thing: session-start injection, the prompt counter, the compaction
nudge, `/log`, `/pref`, and the launcher.

Every other agent gets the vault through **MCP** — `search_memory`, `write_note`,
`append_daily`, `reindex` — which is a real integration but not the same one: nothing is
injected automatically, you have to ask. The installer merges the server into Cursor's config;
for Codex and others it writes the stdio command to `.pluto/mcp-stdio-command.txt` rather than
guessing at a config schema that moves.

## How it works

Four hooks, no model calls, zero background spend:

| Hook | Does |
|---|---|
| `SessionStart` | injects `context.md` + `rules.md` + the tail of the last daily log |
| `UserPromptSubmit` | every 20 prompts, reminds you the session is worth logging |
| `PreCompact` | says "write anything durable down now", before the detail is gone |
| `SessionEnd` | appends a factual stub — time, prompt count. No invented summary. |

Content lives in five places: `daily/` (append-only session logs), `notes/` (durable),
`projects/` (one file each), `inbox/` (raw capture), `archive/`.

**The project registry is your notes.** `pluto api-server` resolves through `path:` in the
frontmatter of `projects/api-server.md` — a file you were going to write anyway. There is no
second list to keep in sync, so the list can never disagree with reality.

See [docs/DESIGN.md](docs/DESIGN.md) for why it is built this way — the parts that took a
few wrong turns first.

## Requirements

- macOS (Apple Silicon or Intel). Linux runs the core; `backup.sh` and the Homebrew paths assume macOS.
- `git`, `python3`. Bash 3.2 is enough — the shipped scripts target what macOS actually has.
- Optional: [Ollama](https://ollama.com) for the semantic tier, `age` + `coreutils` for encrypted backup.

The installer checks the one that actually bites first: macOS system `python3` is often built
without sqlite extension support, which `sqlite-vec` needs. It looks for an interpreter that
has it **before** downloading a gigabyte of model.

## Non-goals

- **No LLM calls in hooks.** A summarizer hook that runs in the background spends tokens
  forever to produce text nobody reads. `/log` is manual and that is the point.
- **No cloud sync of the vault itself.** A file-sync daemon over a git repo gives you
  `file (1).md` and a broken index. Use a private git remote.
- **No web UI, no server, no daemon.** It is files and four shell scripts.

## License

MIT. See [LICENSE](LICENSE).
