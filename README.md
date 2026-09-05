![pluto](docs/pluto-banner.svg)

# pluto

Persistent memory for a coding agent, made of plain markdown files you own.

Your agent starts every session knowing nothing. Pluto is a directory of notes plus a few
hooks that put the right ones in front of it at the start of every session: who you are,
what you are working on now, and the corrections you already made once. Everything is a
file you can read, edit in any editor, grep, and commit. There is no database of record,
no server, and no background process.

It also ships a launcher, because the other half of the problem is getting to the right
directory with the right question already typed.

```
pluto                                     pick a project, open it
pluto api-server                          open that one
pluto api-server why does the test fail   open it, seeded with the question
pluto how can I clean my mac safely?      just ask, from wherever you are
pluto --status                            what moved since you last looked
```

This is a reference implementation, not a framework. It was extracted from a vault in
daily use and published because the design is worth copying, not because it wants to be
your dependency. Fork it and change it.

---

## Contents

- [Install](#install)
- [Uninstall](#uninstall)
- [Requirements](#requirements)
- [What you get](#what-you-get)
- [Command reference](#command-reference)
- [Free text](#free-text)
- [Model tier](#model-tier)
- [Local commands](#local-commands)
- [Adding projects and completion](#adding-projects-and-completion)
- [Agents](#agents)
- [Semantic search](#semantic-search)
- [Hooks](#hooks)
- [Upgrading: code versus content](#upgrading-code-versus-content)
- [Shell integration](#shell-integration)
- [Sync and backup](#sync-and-backup)
- [Configuration reference](#configuration-reference)
- [Platform support](#platform-support)
- [Troubleshooting](#troubleshooting)
- [Non-goals](#non-goals)

---

## Install

```bash
git clone https://github.com/hsn-ylmz/pluto.git
cd pluto
./install.sh
```

The installer asks before each optional step and prints everything it would do with
`--dry-run`. Nothing outside the vault is touched unless you agree to it, and one flag
(`--no-global`) turns all of that off at once.

Useful variations:

```bash
./install.sh --dry-run                     show every action, write nothing
./install.sh --vault ~/second-brain        build it somewhere else
./install.sh --no-semantic --no-global     core only; writes nothing outside the vault
./install.sh --semantic                    add local search to an existing vault later
./install.sh -y                            take the default for every prompt
```

Re-running is safe and is the supported way to upgrade. See
[Upgrading](#upgrading-code-versus-content).

### What it creates

```
~/pluto/
  CLAUDE.md            router: load order, where things go, memory protocol
  context.md           who you are and what is active now; injected every session
  rules.md             standing corrections; injected every session
  preferences.md       how you want to be worked with; injected in every project
  daily/               append-only session logs, YYYY-MM-DD.md
  notes/               durable knowledge
  projects/            one file per project; this is also the launcher's registry
  inbox/               raw capture
  archive/
  bin/                 the pluto launcher and the shared registry reader
  completions/         zsh and bash completion
  .claude/             hooks, scripts, settings, slash commands
  .pluto/              the embedding index
  .venv/               python environment for the semantic tier
```

---

## Uninstall

```bash
./uninstall.sh              # everything pluto installed; your notes are kept
./uninstall.sh --dry-run    # show what that would remove
./uninstall.sh --everything # the notes as well, after confirming
```

Six steps, safest first, each one confirmed:

1. the pluto blocks in your shell rc files
2. the global layer in `~/.claude`: hook, `/pref`, the SessionStart entry, the MCP server
3. generated state in the vault: `.venv`, the embedding index, `settings.local.json`
4. installed code in the vault: `bin/`, `.claude/`, `completions/`
5. packages that pluto installed, and only those, in reverse install order
6. your notes and markdown

Reverse order matters: removing Node.js before the npm package it installed would destroy
the npm needed to remove it, leaving an orphaned binary behind.

Two things it will not do. It will not remove a package it did not install: the installer
records what it installed in `.pluto/installed-by-pluto`, and anything absent from that
file was on the machine before pluto and is left alone. And it will not delete your notes
as part of a default run, not even with `--yes`; when you do ask, it offers to write a git
bundle of the entire history first and stops rather than deleting anything unbacked.

Shell rc files and `~/.claude/settings.json` are edited between markers or by key, never
rewritten, so the rest of your configuration survives untouched.

Stopping after any step leaves a coherent machine. Stopping after step four leaves a
directory of markdown that opens in any editor, which is the point of the format.

## Requirements

Required:

- an agent CLI, if you want `pluto` to actually open sessions. The installer offers to
  install Claude Code for you, pulling Node.js first if npm is missing. It installs the
  program and nothing else: signing in is yours to do, and pluto never goes near
  credentials. `PLUTO_AGENT` points the launcher at any other command that takes
  `[flags] [prompt]`, and everything that does not start a session works without any
  agent at all.
- `git`
- `python3` (the hooks use it to escape JSON; the semantic tier needs it to load sqlite
  extensions, which the installer checks for explicitly)
- bash 3.2 or newer. The shipped scripts target what macOS actually has, so nothing needs
  a modern bash.

Optional, per tier:

- [Ollama](https://ollama.com) and roughly 1 GB of disk for the embedding model, for
  semantic search. On Linux the installer can install Ollama for you; its own installer
  needs `curl`, `tar` and `zstd`, which are pulled in first so you do not discover them one
  failed run at a time.
- `age` and `coreutils`, for encrypted backup

Not required: `curl`. Every HTTP call here prefers `curl`, falls back to `wget`, and falls
back again to `python3`, which is already required — so a machine with none of the usual
download tools still works.

### On Debian and Ubuntu

Stock Debian and Ubuntu ship `python3` with `ensurepip` split into a separate package, so
`python3 -m venv` fails out of the box with an error about ensurepip. The semantic tier
needs a virtualenv, so install this first if you want it:

```bash
sudo apt install python3-venv        # or python3.12-venv, matching your python3
```

You do not have to do this before installing. The installer detects it, names the exact
package for your machine, offers to run the command, and completes the core install
regardless. Add the tier afterwards with `./install.sh --semantic`.

### The check that runs before anything is downloaded

macOS system `python3` is frequently built without sqlite extension support, which
`sqlite-vec` needs, and Debian's is frequently missing `ensurepip`. Either failure would
otherwise surface after a gigabyte of model download. Pluto tests both before fetching
anything, picks an interpreter that satisfies both, and tells you which one it chose.

---

## What you get

| Tier | What it adds | What it costs |
|---|---|---|
| core | vault, git repo, session hooks, launcher, completion, `/log` | nothing; always installed |
| semantic | local embeddings, search over everything, MCP server | Ollama and a model download |
| global | `preferences.md` injected into every project, `/pref` | writes into `~/.claude` |
| cloud | private git remote, age-encrypted offsite bundle | your own remote |

Declining every optional tier still leaves a working vault, a working launcher and working
session injection. The heavy tier is offered last, on purpose.

---

## Command reference

```
pluto                          pick a project interactively (fzf, or a numbered menu)
pluto NAME [agent args...]     open NAME, forwarding any remaining flags to the agent
pluto TEXT...                  ask; see Free text

-l, --list                     list projects with their status line
    --names                    one bare project name per line, for scripts and completion
    --path NAME                print NAME's directory and exit
    --create NAME [...]        register a project; see below
    --edit NAME                open NAME's registry entry in $EDITOR
    --remove NAME              delete NAME's registry entry, after confirming
    --status                   git and mtime state of every registered project
    --ask TEXT...              force TEXT to be a question, never a project name
-h, --help                     full usage
    --version
```

Reserved commands are only reserved in first position. Any other leading flag opens the
picker and is forwarded, so `pluto --continue` picks a project and resumes its last
session. Flags after a project name are never pluto's.

There is no `pluto cd`, because a child process cannot change your shell's directory.
Compose instead:

```bash
cd "$(pluto --path api-server)"
```

---

## Free text

Anything that is neither a reserved command nor a registered project is treated as a
question. Pluto starts an interactive agent session seeded with it.

Where it runs: the registered project your current directory is inside, or the vault if
you are outside all of them. When projects are nested, the longest matching path wins.
It always prints which directory it chose.

Two shapes deliberately stay project lookups and fail with `unknown project`:

```
pluto backup                 a single bare, name-shaped word
pluto api-sevrer --continue  an unknown word carrying agent flags
```

Both are far likelier to be a typo than a question, and silently turning a typo into a
prompt buries the message telling you the name is wrong. Use `--ask` to force either
through. `--ask` is also the only way to drive free text without a terminal.

One shell detail that is not cosmetic: zsh expands `?` and `*` before pluto is ever
reached, so an unquoted question dies in the shell with `no matches found`. The installer
adds `alias pluto='noglob pluto'` for zsh users, which fixes `?`, `*` and `[`. Apostrophes
and `& | ; ( ) < >` still need quoting:

```bash
pluto "what's eating my disk?"
```

Bash needs no alias; it leaves unmatched globs alone.

---

## Model tier

Vault work is daily stuff: a log entry, a capture, a question you want answered rather
than researched. It does not need the expensive model. A registered project is real work
and gets your default.

```
pluto how do I clear the DNS cache      vault   -> cheap model
pluto api-server audit the parser       project -> your default
pluto -q api-server what does WP2 mean  forced cheap
pluto --deep how should I structure     forced default, in the vault
```

Nothing classifies the question. It is a directory test, so the launch path stays free of
network calls and latency, and you can always predict what you will get.

| Variable | Effect |
|---|---|
| `PLUTO_QUICK_MODEL` | model for vault work. Defaults to `haiku`. Set it empty to turn tiering off entirely. |
| `PLUTO_DEEP_MODEL` | model for project work. Unset, meaning whatever your agent already uses. |

`--model` is Claude Code's flag, so this only applies when your agent is Claude Code. Any
other `PLUTO_AGENT` gets its arguments untouched.

## Adding projects and completion

```bash
pluto --create api-server --path ~/code/api-server --status "serves the API"
pluto --create                                      # or answer three prompts
```

Flags make it scriptable; with `--path` given it needs no terminal at all. Creating a
missing directory is never silent, so you are either asked or you passed `--mkdir`.

A new project is a usable CLI argument immediately. `pluto api-server` resolves it, and
TAB completion offers it on the next keystroke. Nothing is cached and nothing is
regenerated, because the completions call `pluto --names`, which reads `projects/*.md` on
every invocation.

**The registry is your notes.** `pluto api-server` resolves through `path:` in the
frontmatter of `projects/api-server.md`, a file you were going to write anyway:

```markdown
---
name: api-server
path: ~/code/api-server
---

## Status
serves the API. Blocked on the auth migration.
```

The first non-empty line under `## Status` becomes the description in `pluto --list`.
Everything else is free prose. There is no separate config file listing your projects, so
the list cannot disagree with your notes.

Completion for zsh and bash is installed into `completions/` and wired into your rc file.
On a shell that has never run `compinit`, the installer bootstraps it; on a configured
shell it stays out of the way.

---

## Local commands

Anything machine-specific goes in `$PLUTO/bin/pluto-local.sh` rather than in the launcher.
The installer has no template for that file, so it is never written, never diffed and
never overwritten: your commands survive every re-install and every upgrade.

```bash
cp docs/pluto-local.example.sh ~/pluto/bin/pluto-local.sh
```

It is sourced after every one of the launcher's own functions is defined, so it can call
`registry`, `resolve`, `resolve_or_die`, `launch`, `die`, `confirm` and the rest, and
before dispatch, so it can add commands.

```bash
pluto_local_dispatch() {
  case "${1:-}" in
    --note) shift; printf -- '- %s\n' "$*" >> "$PLUTO/daily/$(date +%F).md"; return 0 ;;
  esac
  return 1        # not mine; let pluto carry on
}

pluto_local_commands() {        # optional, for --help
  printf '%s\n' '--note:append a line to today log'
}
```

Return 0 when you handled the command and pluto exits; return non-zero and pluto continues
with its own dispatch. Its own commands are matched **first**, so a local file cannot
shadow `--list` or `--status` even by accident, and project names and free text are still
reached when nothing local matches.

The uninstaller knows about it too: it removes `bin/pluto` and `bin/_pluto_registry.sh` by
name rather than deleting `bin/`, and tells you the file was kept.

## Agents

**Claude Code** gets everything: session-start injection, the prompt counter, the
compaction nudge, `/log`, `/pref`, the launcher, and the MCP server.

**Every other agent** reaches the vault through MCP: `search_memory`, `write_note`,
`append_daily`, `reindex`. This is a real integration, but it is not the same one. Nothing
is injected automatically; you have to ask. Since MCP lives in the semantic tier, that
tier is not optional for these agents, and the installer says so rather than leaving them
with a directory of markdown and no way in.

The installer merges the server into Cursor's config, preserving any servers already
there. For Codex and anything else it writes the stdio command to
`.pluto/mcp-stdio-command.txt` instead of guessing at a config schema that moves.

---

## Semantic search

Chunks every markdown file in the vault, embeds each chunk with a local Ollama model, and
stores the vectors in sqlite-vec. Nothing leaves the machine.

- Model: `nomic-embed-text-v2-moe`, 768 dimensions, cosine distance
- Chunking: 1000 characters with 150 of overlap; the model caps at 512 tokens, so this
  leaves headroom
- Storage: `.pluto/index.db`, gitignored
- Incremental: chunks are keyed by SHA, so reindexing only embeds what changed and drops
  chunks whose source text is gone

The index refuses to run against a schema built by a different model or metric rather than
silently returning nonsense, because vectors from different models are not comparable.

If nothing is listening once Ollama is installed, the installer offers to run
`ollama serve` in the background and waits for it. That is what happens on a container or
on WSL, where the systemd unit its installer writes is never started. It is a background
process rather than a service: it stops when the machine does.

Ollama does not have to be on the same machine:

```bash
PLUTO_OLLAMA_URL=http://gpu-box.local:11434 ./install.sh --semantic
```

Rebuild the index by hand at any time:

```bash
~/pluto/.venv/bin/python ~/pluto/.claude/scripts/pluto_index.py
```

---

## Hooks

Four hooks, no model calls, zero background token spend.

| Hook | What it does |
|---|---|
| SessionStart | injects `context.md`, `rules.md`, and the tail of the most recent daily log |
| UserPromptSubmit | every 20 prompts, reminds you the session is worth logging |
| PreCompact | says to write anything durable down now, before the detail is compacted away |
| SessionEnd | appends a factual stub: clock time and prompt count. No invented summary. |

The obvious missing feature is a hook that summarises each session. It is deliberately
absent. A background summariser spends tokens on every session forever and produces text
whose only reader is a future summariser, while making the log look maintained. `/log` is
manual, and a model that was actually in the conversation writes it.

---

## Upgrading: code versus content

Re-run `install.sh`. It knows which files are yours.

**Code** is always brought up to date: `bin/`, `.claude/hooks/`, `.claude/scripts/`,
`completions/`, `settings.json`. A stale hook is a bug, not a preference. If your copy
differs, the previous version is saved next to it as `.bak` first.

**Content** is created once and then never touched: `context.md`, `rules.md`,
`preferences.md`, `projects/`, `notes/`, `daily/`. Not rewritten, not diffed, not backed
up, because there is nothing to compare against. The moment the file exists it is yours.

Everything that writes outside the vault is behind a single flag, which is what makes the
installer testable against throwaway vaults without reaching into a real environment.

---

## Shell integration

Which file a line goes in decides whether `pluto` exists at all, so the installer is
specific about it.

| Shell | File | Read by |
|---|---|---|
| zsh | `~/.zshenv` | every zsh, including scripts and `ssh host 'pluto ...'` |
| zsh | `~/.zshrc` | interactive shells only |
| bash | `~/.profile` | login shells only |
| bash | `~/.bashrc` | interactive non-login shells, which is what a terminal window is |

`PLUTO_HOME` and `PATH` go where every shell reads them:

```sh
export PLUTO_HOME="$HOME/pluto"
case ":$PATH:" in *":$HOME/pluto/bin:"*) ;; *) export PATH="$HOME/pluto/bin:$PATH" ;; esac
```

For zsh that is `.zshenv` and nothing else. For bash it goes in **both** `.profile` and
`.bashrc`: neither covers both cases on its own, and Ubuntu's stock `.bashrc` does not
source `.profile`. Environment in `.profile` alone gives you `pluto: not found` in an
ordinary terminal. The `PATH` line is append-guarded, so repeated sourcing cannot stack
duplicates.

The interactive pieces go in `.zshrc` or `.bashrc`, since an alias and a completion mean
nothing without a keyboard:

```zsh
alias pluto='noglob pluto'
(( $+functions[compdef] )) || { autoload -Uz compinit && compinit -u }
[ -f "$PLUTO_HOME/completions/pluto.zsh" ] && source "$PLUTO_HOME/completions/pluto.zsh"
```

Each block carries its own marker, so re-running never duplicates either one, and a file
holding both stays idempotent per block. `--no-shell` skips all of it and prints the lines
for you to add by hand.

## Sync and backup

Sync is a private git remote of **your own** — your GitHub, GitLab, or any host you can
push to. Create an empty private repo, then give the installer its URL, or add it later
with `git -C ~/pluto remote add origin <your-url>`. Nothing here ships a remote, defaults
to one, or has any account baked in: the installer asks, the field starts empty, and if
you leave it empty your vault stays a local git repo.

Your vault is your notes. Keep that repo private.

Git gives real merge semantics; a file-sync daemon over a git repo gives you
`file (1).md` and a broken index. Do not put this vault in a folder managed by Dropbox,
iCloud Drive or Google Drive.

Backup is separate and encrypted. `backup.sh` bundles the whole repo with
`git bundle --all`, encrypts it with `age -p`, and copies it to a cloud folder. The
installer detects what is actually mounted under `~/Library/CloudStorage` and lets you
pick, rather than hardcoding a provider.

A cloud mount can hang rather than fail, so the script probes it under a timeout and bails
loudly instead of piping a bundle into a wedged filesystem.

---

## Configuration reference

Environment variables:

| Variable | Meaning |
|---|---|
| `PLUTO_HOME` | vault location. Defaults to `~/pluto`. Every script falls back to that default, because hooks also run in shells that never read your rc files. |
| `PLUTO_AGENT` | the CLI the launcher runs. Defaults to `claude`. The installer sets it for you when you pick a different agent. |
| `PLUTO_QUICK_MODEL` | model for vault work. Defaults to `haiku`; empty disables tiering. |
| `PLUTO_DEEP_MODEL` | model for project work. Unset means the agent's own default. |
| `PLUTO_OLLAMA_URL` | where Ollama lives. Defaults to `http://localhost:11434`. |
| `PLUTO_BACKUP_DIR` | overrides the backup target chosen at install time. |
| `PLUTO_DRY_RUN` | makes the launcher print its target instead of starting an agent. Used by the test suite. |

Installer flags:

| Flag | Effect |
|---|---|
| `--vault PATH` | where to build the vault |
| `--agent NAME` | `claude-code`, `cursor`, `codex`, `other`, `none` |
| `--semantic` / `--no-semantic` | decide the semantic tier without being asked |
| `--cloud` / `--no-cloud` | decide sync and backup without being asked |
| `--no-shell` | do not touch any rc file; print the lines instead |
| `--no-global` | write nothing outside the vault |
| `-y`, `--yes` | take the default for every prompt |
| `-n`, `--dry-run` | print every action, write nothing |

---

## Platform support

macOS and Linux, detected in preflight along with the package manager, which the installer
then reports back to you.

| Platform | Package manager | Notes |
|---|---|---|
| macOS | Homebrew | if it is missing, that is detected and the install is offered, since it is how macOS gets age, coreutils, fzf and Ollama |
| Debian, Ubuntu | apt | `python3-venv` is a separate package; see above |
| Fedora, RHEL | dnf | |
| Arch | pacman | |
| openSUSE | zypper | |
| anything else | none | the core still installs; optional extras are printed for you to install by hand |

Every optional dependency resolves through one mapping, so `age`, `coreutils`, `fzf`, the
venv module and a python3 with sqlite extensions each produce the right command for your
machine. Ollama is the exception with no distribution package: macOS uses Homebrew, Linux
uses the documented install script.

Installing is the default, because it is cheap and the uninstaller records and reverses
exactly what was installed. Claude Code, the Node.js it needs, Ollama and the embedding
model are all offered with yes as the default. The one exception is the Homebrew
bootstrap, which stays at no: installing a package manager into `/opt` is a different
order of change from installing one program with it.

`sudo` is used only when it is both needed and available. As root the prefix is dropped
entirely, which matters on container images that ship no `sudo` binary; on a machine that
is neither root nor sudo-capable, the command is printed rather than silently skipped.

The tools that differ between BSD and GNU, `stat` and `date`, are probed at runtime rather
than assumed. `backup.sh` is macOS-specific, since it looks under `~/Library/CloudStorage`.

Verified end to end on all of these:

- a clean-room install into an isolated `HOME` on macOS, every tier
- a `git clone` and install on a Debian container that had never seen pluto, with the
  embedding model served from another host
- stock Ubuntu with no `python3-venv`, which is the state Ubuntu actually ships in
- recovery on Ubuntu from a virtualenv left half-built by an interrupted install

The container definitions for those runs are in [`test/`](test/), because a from-zero
claim is worth exactly as much as the clean room you can prove it in. The Ubuntu image
deliberately installs nothing beyond `git`, `python3`, `curl` and `zsh`: an earlier
version of the Debian image pre-installed `python3-venv`, and that single convenience hid
a real bug from testing entirely.

The installer finishes with a verify phase of 15 checks, including a JSON-RPC round-trip
against the MCP server. That phase has caught real bugs, which is the only reason to have
one.

---

## Troubleshooting

**`exec: claude: not found`, or `pluto: 'claude' is not on your PATH`.** The launcher hands
the directory and your question to an agent CLI, and that CLI is a separate program. Install
Claude Code with `npm install -g @anthropic-ai/claude-code`, or point pluto at whatever you
use:

```bash
export PLUTO_AGENT=your-agent-command
```

The registry half of pluto never needed it: `--list`, `--names`, `--path`, `--status`,
`--create`, `--edit` and `--remove` all work with no agent installed.

**`pluto: command not found` right after a successful install.** You are in a shell that
never read the file the environment went into. `source ~/.profile` fixes the session; for a
real fix the environment belongs in `~/.zshenv` for zsh, and in both `~/.profile` and
`~/.bashrc` for bash. Re-running the installer writes them correctly.

**`zsh: no matches found: safely?`** The `noglob` alias is missing. It is added to your
interactive rc by the installer; open a new shell, or add
`alias pluto='noglob pluto'` yourself.

**TAB completion does nothing.** Completion needs `compinit` to have run before
`completions/pluto.zsh` is sourced. The installer's block handles both cases; if you added
the lines by hand, check the order. `echo $_comps[pluto]` should print `_pluto`.

**`unknown project` for something you meant as a question.** A single bare word, or an
unknown word followed by flags, is read as a project name on purpose. Use
`pluto --ask ...`.

**`ollama embedding failed`.** The URL in the message is where it looked. Start Ollama, or
set `PLUTO_OLLAMA_URL`.

**`index schema mismatch`.** The index was built with a different model or distance
metric. Delete `.pluto/index.db` and reindex; mixing them returns confident nonsense.

**`sqlite-vec` will not import.** Your `python3` cannot load sqlite extensions. Install one
that can, for example `brew install python@3.13`, and re-run with `--semantic`.

**"The virtual environment was not created successfully because ensurepip is not
available."** Debian and Ubuntu package `ensurepip` separately:

```bash
sudo apt install python3-venv
./install.sh --semantic
```

The core install is unaffected by this; only the semantic tier waits.

**The semantic tier says it is already installed, but `sqlite-vec` and the MCP server fail
verification.** An earlier install was interrupted after the virtualenv directory was
created but before its packages went in. Current versions detect this and rebuild it. If
you are on an older copy, delete it and re-run:

```bash
rm -rf ~/pluto/.venv
./install.sh --semantic
```

---

## Non-goals

- **No model calls in hooks.** The system spends zero tokens in the background.
- **No cloud sync of the vault itself.** Use a private git remote.
- **No web UI, no server, no daemon.** It is files, a few shell scripts and three small
  python ones.
- **Not a framework.** There is no plugin system and no configuration language. The
  configuration is the markdown.

---

## Further reading

[docs/DESIGN.md](docs/DESIGN.md) explains why it is built this way, including the
decisions that went the other way first.

## License

MIT. See [LICENSE](LICENSE).
