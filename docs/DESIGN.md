# Design notes

Why pluto is shaped the way it is. Most of these are decisions that went the other way first.

## Hooks never call a model

The obvious feature is a hook that summarises each session into `daily/`. It is also the
first thing to delete. A background summariser spends tokens on every session forever, and
produces text whose only reader is a future summariser. Worse, it makes the log *look*
maintained while quietly filling with plausible nothing.

So `SessionEnd` writes one factual line — clock time, prompt count — and nothing else. Real
content only appears when you run `/log` and a model that was actually in the conversation
writes it. The prompt counter exists to nag you into doing that. The system spends zero
tokens in the background, and every word in `daily/` was written by something that was there.

## The registry is your notes, not a config file

`pluto api-server` resolves through `path:` in the frontmatter of `projects/api-server.md`.

The alternative — `~/.config/pluto/projects.toml` — is a second list of the same things. Two
lists drift: you rename a directory, fix the config, and the note still says the old path;
or you archive a project and it lingers in the launcher for a year. Reading the frontmatter
of a file you were going to write anyway means there is exactly one place a project exists,
and `pluto --list` cannot show you something your notes disagree with.

The cost is a parser that has to read `path:` from the frontmatter block *only* — a prose
body may well mention other paths. That is nine lines of awk, in one file
(`bin/_pluto_registry.sh`) sourced by both the launcher and the status script, so the two can
never disagree either.

## Code is upgraded, content is untouchable

Re-running `install.sh` is the supported upgrade path, which only works if the installer
knows which files are yours.

- **Code** — `bin/`, `.claude/hooks/`, `.claude/scripts/`, `settings.json`. Always rewritten.
  A stale hook is a bug, not a preference. If your copy differs it is saved as `.bak` first.
- **Content** — `context.md`, `rules.md`, `preferences.md`, `projects/`, `notes/`, `daily/`.
  Created once. Never rewritten, never diffed, never backed up, because there is nothing to
  compare against: the moment the file exists it is yours.

Anything that writes outside the vault — `~/.claude`, the shell rc, the global MCP
registration — is behind one flag (`--no-global`, `--no-shell`), so the installer can be
tested against a scratch vault without reaching into a real environment.

## Free text goes straight to the agent

`pluto how can I clean my mac safely?` starts a session seeded with that question. It is the
same launcher, so it lands in the right directory: the registered project your cwd is inside
(longest match wins, so a nested project beats its parent), or the vault when you are outside
one. It always prints which.

Two shapes deliberately stay project lookups and fail with `unknown project`:

```
pluto backup                 one bare, name-shaped word
pluto api-sevrer --continue   unknown word carrying agent flags
```

Both are far likelier to be a typo than a question, and silently turning a typo into a prompt
buries the message that tells you the name is wrong — which is the whole reason the registry
exists. `pluto --ask ...` forces either through.

One shell detail that is not cosmetic: zsh expands `?` and `*` before the launcher is ever
reached, so an unquoted question dies with `no matches found: safely?`. The installer adds
`alias pluto='noglob pluto'` for zsh users. Bash needs nothing — it leaves unmatched globs
alone.

## Everything heavy is optional, and asked for last

The semantic tier needs Ollama and a ~1 GB model. It is genuinely useful and it is genuinely
not worth gating a markdown vault behind, so declining it leaves everything else working.

The failure it *does* guard against is specific: macOS system `python3` is frequently built
without sqlite extension support, which `sqlite-vec` requires. Discovered the honest way,
that surfaces as an `ImportError` several hundred megabytes into a model download. The
installer picks an interpreter that can load extensions before anything is fetched, and says
which one it chose.

Non-Claude agents reach the vault only through MCP, and MCP lives in this tier — so for them
it is not optional. The installer says so rather than leaving them with a directory of
markdown and no way in.

## Append-only, and one snapshot

`daily/` is append-only. Never rewrite a past day: a log you edit is a log you cannot trust,
and the whole value of the file is that it says what you actually thought on Tuesday.

`context.md` is the opposite — a snapshot of *now*, deliberately not a history, because it
enters the context window on every single session. It has a 40-line budget for that reason.
Compacting `daily/` into `notes/` is a deliberate monthly act, done by a human, not a cron job.

`pluto --status` exists to make that easy: it prints the git and mtime state of everything in
the registry, ready to paste into `## Active`. It deliberately does **not** write `context.md`
itself. Git state tells you when something moved, never what you are trying to do with it, and
the second half is the only reason the file is worth injecting.
