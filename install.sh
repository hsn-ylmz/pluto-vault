#!/bin/bash
# pluto installer — builds a working vault from nothing.
#
# Everything is optional except PHASE 1-3. Declining every prompt still leaves you with a
# vault, a launcher and working session hooks; that is the point. Semantic search is the
# only heavy dependency and it is the last thing asked for.
#
# Re-running is safe and is the supported way to upgrade: code files (bin/, .claude/) are
# overwritten, content files (context.md, rules.md, projects/, notes/, daily/) are never
# touched once they exist. That split is the whole never-clobber rule.
#
# Targets bash 3.2 (what macOS ships): no mapfile, no associative arrays, no ${v^^}.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/ui.sh
. "$SRC/lib/ui.sh"

VAULT="$HOME/pluto"
AGENT=""
WANT_SEMANTIC="ask"
WANT_CLOUD="ask"
WANT_GLOBAL="ask"
WANT_SHELL="ask"
ASSUME_YES=""
DRY_RUN=""

VENV_PY=""          # filled in by the semantic phase; empty means no MCP
BACKUP_DIR=""
BACKUP_LABEL=""
INSTALLED=0
SKIPPED_TIERS=""

# ------------------------------------------------------------------------------ usage

usage() {
  cat <<EOF
pluto installer

USAGE
  ./install.sh [options]

OPTIONS
  --vault PATH        where to build the vault        (default: ~/pluto)
  --agent NAME        claude-code | cursor | codex | other | none
  --semantic          enable local embeddings + MCP without asking
  --no-semantic       skip it without asking
  --cloud             configure git remote + encrypted backup
  --no-cloud          skip it
  --no-shell          do not touch any shell rc file
  --no-global         write nothing outside the vault (~/.claude, global MCP)
  -y, --yes           take the default for every prompt (implies non-interactive)
  -n, --dry-run       print what would happen, write nothing
  -h, --help          this text

TIERS
  core        vault, git, hooks, launcher, /log            always
  semantic    venv, sqlite-vec, Ollama embeddings, MCP     optional, ~1 GB model
  global      preferences.md injected into every project   optional
  cloud       private git remote + age-encrypted backup    optional

  Non-Claude agents get the vault through MCP only, so for them the semantic tier is
  not optional — without it they have no way in.
EOF
}

# ------------------------------------------------------------------------------ args

while [ $# -gt 0 ]; do
  case "$1" in
    --vault)        shift; [ $# -gt 0 ] || die "--vault needs a path" 2; VAULT="$1" ;;
    --agent)        shift; [ $# -gt 0 ] || die "--agent needs a name" 2; AGENT="$1" ;;
    --semantic)     WANT_SEMANTIC=yes ;;
    --no-semantic)  WANT_SEMANTIC=no ;;
    --cloud)        WANT_CLOUD=yes ;;
    --no-cloud)     WANT_CLOUD=no ;;
    --no-shell)     WANT_SHELL=no ;;
    --no-global)    WANT_GLOBAL=no ;;
    -y|--yes)       ASSUME_YES=1 ;;
    -n|--dry-run)   DRY_RUN=1 ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "unknown option '$1' (try --help)" 2 ;;
  esac
  shift
done

VAULT="${VAULT/#\~/$HOME}"
case "$VAULT" in /*) ;; *) VAULT="$(pwd -P)/$VAULT" ;; esac

case "$AGENT" in
  ''|claude-code|cursor|codex|other|none) ;;
  *) die "unknown --agent '$AGENT' (claude-code, cursor, codex, other, none)" 2 ;;
esac

# ------------------------------------------------------------------------------ helpers

rel() { case "$1" in "$HOME"/*) printf '~/%s\n' "${1#"$HOME"/}" ;; *) printf '%s\n' "$1" ;; esac; }

render_to() { # SRC DST
  sed -e "s|{{VAULT}}|$VAULT|g" \
      -e "s|{{PY}}|${VENV_PY:-/usr/bin/env python3}|g" \
      -e "s|{{BACKUP_DIR}}|$BACKUP_DIR|g" \
      -e "s|{{BACKUP_LABEL}}|$BACKUP_LABEL|g" \
      "$1" > "$2"
}

# Code: always brought up to date, because a stale hook or launcher is a bug, not a choice.
# An existing file that differs is backed up first, so a local edit is never lost silently.
put_code() { # TEMPLATE_REL DST_REL [MODE]
  local src="$SRC/template/$1" dst="$VAULT/$2" mode="${3:-644}" tmp
  [ -f "$src" ] || die "missing template file: $1"
  if [ -n "$DRY_RUN" ]; then dim "code    $(rel "$dst")"; return 0; fi
  mkdir -p "$(dirname "$dst")"
  tmp="$(mktemp)"
  render_to "$src" "$tmp"
  if [ -f "$dst" ]; then
    if cmp -s "$tmp" "$dst"; then rm -f "$tmp"; return 0; fi
    cp "$dst" "$dst.bak"
    warn "$(rel "$dst") changed — previous version kept as $(basename "$dst").bak"
  fi
  mv "$tmp" "$dst"
  chmod "$mode" "$dst"
  INSTALLED=$((INSTALLED + 1))
}

# Content: yours the moment it exists. Never overwritten, never backed up, never diffed.
put_content() { # TEMPLATE_REL DST_REL
  local src="$SRC/template/$1" dst="$VAULT/$2"
  [ -f "$src" ] || die "missing template file: $1"
  if [ -f "$dst" ]; then skip "$(rel "$dst") exists — left alone"; return 0; fi
  if [ -n "$DRY_RUN" ]; then dim "content $(rel "$dst")"; return 0; fi
  mkdir -p "$(dirname "$dst")"
  render_to "$src" "$dst"
  INSTALLED=$((INSTALLED + 1))
}

have() { command -v "$1" >/dev/null 2>&1; }

# python3 must be able to load sqlite extensions or sqlite-vec cannot work. macOS system
# python3 is frequently built without it, and the failure surfaces hundreds of megabytes
# later as an import error — so this is checked before anything is downloaded.
py_loads_extensions() { # PYTHON
  "$1" - <<'PY' >/dev/null 2>&1
import sqlite3
db = sqlite3.connect(":memory:")
db.enable_load_extension(True)
PY
}

# Debian and Ubuntu ship python3 with ensurepip split into a separate package, so
# `python3 -m venv` fails on a stock system with an error about ensurepip. An interpreter
# that cannot build a venv is no use to this tier, so it is a selection criterion, not a
# surprise several steps later.
py_can_venv() { # PYTHON
  "$1" -c "import ensurepip" >/dev/null 2>&1
}

# Set when no interpreter qualifies, so the message can name the actual problem instead of
# saying "none found" for two very different causes.
PY_PROBLEM=""

pick_python() { # -> interpreter on stdout, empty if none qualify
  local c saw_ext=""
  for c in "$(brew --prefix 2>/dev/null)/bin/python3" python3.13 python3.12 python3.11 python3; do
    [ -n "$c" ] || continue
    have "$c" || continue
    py_loads_extensions "$c" || continue
    saw_ext=1
    if py_can_venv "$c"; then command -v "$c"; return 0; fi
    PY_VENV_CANDIDATE="$(command -v "$c")"
  done
  if [ -n "$saw_ext" ]; then PY_PROBLEM=venv; else PY_PROBLEM=extensions; fi
  return 0
}

# The exact command for this machine, not a generic "install the venv package".
venv_fix_hint() { # PYTHON
  local v
  v="$("$1" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo 3)"
  if have apt-get;   then printf 'sudo apt install -y python%s-venv\n' "$v"
  elif have dnf;     then printf 'sudo dnf install -y python3\n'
  elif have pacman;  then printf 'sudo pacman -S --needed python\n'
  elif have brew;    then printf 'brew install python@%s\n' "$v"
  else                    printf 'install the venv/ensurepip module for %s\n' "$1"
  fi
}

want() { # TIER_VAR PROMPT DEFAULT
  case "$1" in
    yes) return 0 ;;
    no)  return 1 ;;
    *)   confirm "$2" "$3" ;;
  esac
}

# ------------------------------------------------------------------------------ phases

phase_preflight() {
  step "PHASE 0 — preflight"
  info "vault:  $(rel "$VAULT")"
  info "source: $(rel "$SRC")"
  [ -n "$DRY_RUN" ] && warn "dry run — nothing will be written"

  case "$(uname -s)" in
    Darwin) ok "macOS" ;;
    Linux)  warn "Linux — the core works; backup.sh and the brew paths assume macOS" ;;
    *)      die "unsupported platform: $(uname -s)" ;;
  esac

  have git     || die "git is required"
  have python3 || die "python3 is required (the hooks use it to escape JSON)"
  ok "git $(git --version | awk '{print $3}'), python3 $(python3 -V 2>&1 | awk '{print $2}')"

  if [ -e "$VAULT" ] && [ ! -d "$VAULT" ]; then
    die "$(rel "$VAULT") exists and is not a directory"
  fi
  if [ -d "$VAULT" ]; then
    if [ -f "$VAULT/CLAUDE.md" ] || [ -d "$VAULT/.claude" ]; then
      ok "existing vault — code will be updated, your notes will not be touched"
    elif [ -n "$(ls -A "$VAULT" 2>/dev/null)" ]; then
      warn "$(rel "$VAULT") is not empty and does not look like a vault"
      confirm "install into it anyway?" n || die "aborted"
    fi
  fi
}

# Runs before any rendering: {{PY}} goes into the script shebangs in PHASE 3, long before
# the semantic tier is offered in PHASE 4. Re-running an existing vault without --semantic
# must not rewrite a working shebang into a broken one.
adopt_venv() {
  if [ -x "$VAULT/.venv/bin/python" ]; then
    VENV_PY="$VAULT/.venv/bin/python"
    step "existing install"
    ok "venv adopted: $(rel "$VENV_PY")"
  fi
}

phase_skeleton() {
  step "PHASE 1 — vault skeleton"
  if [ -z "$DRY_RUN" ]; then
    mkdir -p "$VAULT"/{daily,notes,projects,inbox,archive}
    mkdir -p "$VAULT"/.claude/hooks/.state "$VAULT"/.claude/scripts "$VAULT"/.claude/commands "$VAULT"/.pluto "$VAULT"/bin
  fi
  ok "daily/ notes/ projects/ inbox/ archive/ bin/ .claude/ .pluto/"

  put_code dot-gitignore .gitignore

  if [ -d "$VAULT/.git" ]; then
    skip "git repo already initialised"
  elif [ -n "$DRY_RUN" ]; then
    dim "git init"
  else
    git -C "$VAULT" init -q
    git -C "$VAULT" symbolic-ref HEAD refs/heads/main
    ok "git initialised on main"
  fi
}

phase_content() {
  step "PHASE 2 — content (created once, then yours)"
  put_content CLAUDE.md       CLAUDE.md
  put_content context.md      context.md
  put_content rules.md        rules.md
  put_content preferences.md  preferences.md
  put_content projects/pluto.md   projects/pluto.md
}

phase_code() {
  step "PHASE 3 — code (kept up to date on every run)"
  put_code bin/pluto                        bin/pluto                        755
  put_code bin/_pluto_registry.sh           bin/_pluto_registry.sh           644
  put_code dot-claude/settings.json         .claude/settings.json            644
  put_code dot-claude/commands/log.md       .claude/commands/log.md          644
  put_code dot-claude/commands/pref.md      .claude/commands/pref.md         644
  local h
  for h in session-start prompt-counter session-end pre-compact; do
    put_code "dot-claude/hooks/$h.sh"       ".claude/hooks/$h.sh"            755
  done
  put_code dot-claude/scripts/refresh_active.sh .claude/scripts/refresh_active.sh 755
  put_code dot-claude/scripts/pluto_index.py    .claude/scripts/pluto_index.py    755
  put_code dot-claude/scripts/pluto_search.py   .claude/scripts/pluto_search.py   755
  put_code dot-claude/scripts/pluto_mcp.py      .claude/scripts/pluto_mcp.py      755
  put_code completions/pluto.zsh                completions/pluto.zsh            644
  put_code completions/pluto.bash               completions/pluto.bash           644
  ok "launcher, 4 hooks, 3 scripts, /log, /pref, completions"
}

phase_semantic() {
  step "PHASE 4 — semantic search (optional)"

  if [ -n "$VENV_PY" ] && [ "$WANT_SEMANTIC" != yes ]; then
    skip "semantic tier already installed — pass --semantic to refresh it"
    return 0
  fi
  info "local embeddings via Ollama, indexed into sqlite-vec. Nothing leaves the machine."
  info "cost: a ~1 GB model download. Declining leaves a fully working vault."

  if [ "$AGENT" != "claude-code" ] && [ "$AGENT" != "none" ]; then
    warn "$AGENT reaches the vault through MCP, and MCP lives in this tier — declining"
    warn "leaves it with no way in at all."
  fi

  if ! want "$WANT_SEMANTIC" "install semantic search?" y; then
    skip "semantic search skipped — re-run with --semantic later"
    SKIPPED_TIERS="$SKIPPED_TIERS semantic"
    return 0
  fi

  local py fix
  PY_VENV_CANDIDATE=""
  py="$(pick_python)"
  if [ -z "$py" ]; then
    if [ "$PY_PROBLEM" = venv ]; then
      fix="$(venv_fix_hint "${PY_VENV_CANDIDATE:-python3}")"
      warn "python3 is here but cannot create a virtualenv (ensurepip is missing)"
      info "Debian and Ubuntu split that into its own package. Fix with:"
      info "  $fix"
      if [ -z "$DRY_RUN" ] && have sudo && confirm "run that now?" n; then
        if sh -c "$fix"; then
          py="$(pick_python)"
        else
          warn "that failed — run it yourself, then: ./install.sh --semantic"
        fi
      fi
    else
      warn "no python3 here can load sqlite extensions, which sqlite-vec needs"
      info "fix:  brew install python@3.13   (or any python3 built with extension support)"
    fi
  fi
  if [ -z "$py" ]; then
    info "the vault, launcher and hooks are unaffected; re-run with --semantic when fixed"
    SKIPPED_TIERS="$SKIPPED_TIERS semantic"
    return 0
  fi
  ok "interpreter: $py (loads sqlite extensions, can build a venv)"

  if [ -n "$DRY_RUN" ]; then
    dim "python3 -m venv $(rel "$VAULT")/.venv; pip install mcp sqlite-vec"
    dim "ollama pull nomic-embed-text-v2-moe; build index"
    VENV_PY="$VAULT/.venv/bin/python"
    return 0
  fi

  if [ ! -x "$VAULT/.venv/bin/python" ]; then
    if ! "$py" -m venv "$VAULT/.venv" 2>"$VAULT/.pluto/venv-error.log"; then
      warn "could not create the virtualenv:"
      sed 's/^/      /' "$VAULT/.pluto/venv-error.log" >&2 || true
      info "the vault, launcher and hooks are fine; re-run with --semantic once fixed"
      rm -rf "$VAULT/.venv"
      SKIPPED_TIERS="$SKIPPED_TIERS semantic"
      return 0
    fi
    rm -f "$VAULT/.pluto/venv-error.log"
    ok "venv created"
  else
    skip "venv exists"
  fi
  VENV_PY="$VAULT/.venv/bin/python"

  if ! "$VENV_PY" -m pip install --quiet --upgrade pip >/dev/null 2>&1 \
     || ! "$VENV_PY" -m pip install --quiet mcp sqlite-vec; then
    warn "pip could not install mcp and sqlite-vec (offline, or a proxy in the way)"
    info "retry later with: ./install.sh --semantic"
    VENV_PY=""
    SKIPPED_TIERS="$SKIPPED_TIERS semantic"
    return 0
  fi
  ok "mcp + sqlite-vec installed"

  if ! have ollama && ! curl -sf -m 3 "${PLUTO_OLLAMA_URL:-http://localhost:11434}/api/tags" >/dev/null 2>&1; then
    if have brew && confirm "ollama is not installed. install it with brew?" y; then
      brew install ollama
    else
      warn "no ollama — index and search will not work until it is installed"
      SKIPPED_TIERS="$SKIPPED_TIERS ollama"
      return 0
    fi
  fi
  ok "ollama present"

  local ollama_url="${PLUTO_OLLAMA_URL:-http://localhost:11434}"
  if ! curl -sf -m 3 "$ollama_url/api/tags" >/dev/null 2>&1; then
    warn "ollama not responding at $ollama_url"
    info "start it (\`ollama serve\`, or open the app), then run:"
    info "  $VENV_PY $VAULT/.claude/scripts/pluto_index.py"
    return 0
  fi

  if curl -sf -m 5 "$ollama_url/api/tags" 2>/dev/null | grep -q "nomic-embed-text-v2-moe"; then
    skip "embedding model already pulled"
  elif have ollama; then
    info "pulling nomic-embed-text-v2-moe (~1 GB)"
    ollama pull nomic-embed-text-v2-moe
  else
    # Remote Ollama, no local CLI to pull with. Say where the model has to come from.
    warn "the embedding model is missing and there is no local ollama to pull it"
    info "on the host running $ollama_url:  ollama pull nomic-embed-text-v2-moe"
    SKIPPED_TIERS="$SKIPPED_TIERS model"
    return 0
  fi

  "$VENV_PY" "$VAULT/.claude/scripts/pluto_index.py" || warn "index build failed — fix and re-run pluto_index.py"
}

choose_agent() {
  step "agent"
  if [ -z "$AGENT" ]; then
    info "Claude Code gets everything: hooks, context injection, /log, /pref, the launcher."
    info "Anything else reaches the vault through MCP only — no session injection."
    AGENT="$(menu "which agent do you use?" 1 claude-code cursor codex other none)"
  fi
  ok "agent: $AGENT"
}

phase_agent() {
  step "PHASE 5 — agent wiring"
  if [ "$AGENT" = none ]; then
    skip "no agent wiring requested"
    return 0
  fi

  if [ -z "$VENV_PY" ]; then
    warn "MCP needs the semantic tier (it provides the venv). Skipping agent wiring."
    info "re-run with --semantic to wire it up."
    return 0
  fi

  local cmdline="$VENV_PY $VAULT/.claude/scripts/pluto_mcp.py"

  case "$AGENT" in
    claude-code)
      put_code dot-mcp.json .mcp.json
      if [ -z "$DRY_RUN" ]; then
        printf '{\n  "enabledMcpjsonServers": ["pluto"]\n}\n' > "$VAULT/.claude/settings.local.json"
      fi
      ok "project MCP server configured (.mcp.json)"
      ;;
    cursor)
      merge_json_mcp "$HOME/.cursor/mcp.json" "$cmdline"
      ;;
    codex|other)
      # Deliberately not editing their config: these schemas move, and a wrong entry is
      # worse than an instruction. Write the stdio command where it can be copied from.
      if [ -z "$DRY_RUN" ]; then
        mkdir -p "$VAULT/.pluto"
        printf '%s\n' "$cmdline" > "$VAULT/.pluto/mcp-stdio-command.txt"
      fi
      ok "stdio command written to .pluto/mcp-stdio-command.txt"
      info "add it to your agent as an MCP server of type stdio:"
      dim "$cmdline"
      ;;
  esac
}

merge_json_mcp() { # CONFIG_PATH CMDLINE
  local cfg="$1"
  if [ -n "$DRY_RUN" ]; then dim "merge pluto into $(rel "$cfg")"; return 0; fi
  mkdir -p "$(dirname "$cfg")"
  VENV_PY="$VENV_PY" VAULT="$VAULT" CFG="$cfg" python3 - <<'PY'
import json, os, pathlib
cfg = pathlib.Path(os.environ["CFG"])
data = {}
if cfg.exists() and cfg.stat().st_size:
    try:
        data = json.loads(cfg.read_text())
    except json.JSONDecodeError:
        raise SystemExit(f"refusing to touch {cfg}: it is not valid JSON")
servers = data.setdefault("mcpServers", {})
servers["pluto"] = {
    "command": os.environ["VENV_PY"],
    "args": [os.environ["VAULT"] + "/.claude/scripts/pluto_mcp.py"],
}
cfg.write_text(json.dumps(data, indent=2) + "\n")
PY
  ok "pluto merged into $(rel "$cfg")"
}

# Everything in this phase writes OUTSIDE the vault — ~/.claude and the user's global MCP
# registration. One flag turns all of it off, so a test run can never reach into the real
# environment: --no-global.
phase_global() {
  step "PHASE 6 — global layer (optional, writes outside the vault)"
  info "injects preferences.md into every session in every project, read-only."
  if [ "$AGENT" != "claude-code" ]; then
    skip "Claude Code only"
    return 0
  fi
  if ! want "$WANT_GLOBAL" "install it?" y; then
    skip "skipped — nothing outside $(rel "$VAULT") was touched"
    SKIPPED_TIERS="$SKIPPED_TIERS global"
    return 0
  fi

  local hook="$HOME/.claude/hooks/pluto-global-start.sh"
  if [ -n "$DRY_RUN" ]; then
    dim "install $(rel "$hook") and merge it into ~/.claude/settings.json"
    return 0
  fi
  mkdir -p "$HOME/.claude/hooks" "$HOME/.claude/commands"
  render_to "$SRC/template/global/pluto-global-start.sh" "$hook"
  chmod 755 "$hook"
  ok "$(rel "$hook")"

  # Merging, not replacing: an existing SessionStart array that gets overwritten is the
  # single most common way this setup silently breaks someone's other hooks.
  local merged
  merged="$(HOOK="$hook" python3 - <<'PY'
import json, os, pathlib
p = pathlib.Path.home() / ".claude" / "settings.json"
data = {}
if p.exists() and p.stat().st_size:
    try:
        data = json.loads(p.read_text())
    except json.JSONDecodeError:
        raise SystemExit(f"refusing to touch {p}: it is not valid JSON")
cmd = f'"{os.environ["HOOK"]}"'
hooks = data.setdefault("hooks", {})
starts = hooks.setdefault("SessionStart", [])
flat = json.dumps(starts)
if "pluto-global-start.sh" not in flat:
    starts.append({"hooks": [{"type": "command", "command": cmd, "timeout": 10}]})
    p.write_text(json.dumps(data, indent=2) + "\n")
    print("added")
else:
    print("already present")
PY
)"
  ok "~/.claude/settings.json SessionStart hook: $merged"
  cp "$SRC/template/dot-claude/commands/pref.md" "$HOME/.claude/commands/pref.md"
  ok "/pref available everywhere"

  if [ -n "$VENV_PY" ] && have claude; then
    if confirm "register the pluto MCP server for every project too?" y; then
      claude mcp add -s user pluto -- "$VENV_PY" "$VAULT/.claude/scripts/pluto_mcp.py" \
        >/dev/null 2>&1 && ok "registered globally" || warn "claude mcp add failed — add it by hand"
    fi
  fi
}

# Two blocks, in two files, because they answer two different questions.
#
# PLUTO_HOME and PATH belong everywhere a shell runs — scripts, `ssh host pluto --names`,
# CI, a container's `zsh -lc`. zsh reads .zshrc ONLY for interactive shells, so env vars
# placed there leave `pluto` missing from every non-interactive invocation. .zshenv is read
# by every zsh there is.
#
# The alias and the completion are meaningless without a keyboard, so those stay in the
# interactive rc where they belong.
phase_shell() {
  step "PHASE 7 — shell"
  local env_rc inter_rc is_zsh="" start="# >>> pluto >>>" end="# <<< pluto <<<"
  case "${SHELL:-}" in
    */zsh)  env_rc="$HOME/.zshenv"; inter_rc="$HOME/.zshrc";  is_zsh=1 ;;
    */bash) env_rc="$HOME/.profile"; inter_rc="$HOME/.bashrc" ;;
    *)      env_rc="$HOME/.profile"; inter_rc="" ;;
  esac

  if [ "$WANT_SHELL" = no ]; then
    skip "not touching any rc file"
    print_shell_block "$is_zsh"
    return 0
  fi

  info "env -> $(rel "$env_rc")   (every shell, so scripts and ssh see pluto too)"
  [ -n "$inter_rc" ] && info "interactive -> $(rel "$inter_rc")   (completion$([ -n "$is_zsh" ] && printf ', noglob alias'))"

  if ! confirm "append pluto blocks to them?" y; then
    skip "declined"
    print_shell_block "$is_zsh"
    return 0
  fi
  if [ -n "$DRY_RUN" ]; then
    dim "append env block to $(rel "$env_rc")"
    [ -n "$inter_rc" ] && dim "append interactive block to $(rel "$inter_rc")"
    return 0
  fi

  if [ -f "$env_rc" ] && grep -q "$start" "$env_rc" 2>/dev/null; then
    skip "$(rel "$env_rc") already has a pluto block"
  else
    {
      printf '\n%s\n' "$start"
      printf 'export PLUTO_HOME="%s"\n' "$VAULT"
      printf 'case ":$PATH:" in *":%s/bin:"*) ;; *) export PATH="%s/bin:$PATH" ;; esac\n' "$VAULT" "$VAULT"
      printf '%s\n' "$end"
    } >> "$env_rc"
    ok "$(rel "$env_rc")"
  fi

  [ -n "$inter_rc" ] || return 0
  if [ -f "$inter_rc" ] && grep -q "$start" "$inter_rc" 2>/dev/null; then
    skip "$(rel "$inter_rc") already has a pluto block"
    return 0
  fi
  {
    printf '\n%s\n' "$start"
    if [ -n "$is_zsh" ]; then
      printf '# Free text goes straight to your agent: `pluto how do I clean my mac safely?`\n'
      printf '# noglob stops zsh expanding the ? and * before pluto ever sees them.\n'
      printf "alias pluto='noglob pluto'\n"
      # Only bootstrap the completion system if nothing else has. A configured zsh already
      # ran compinit its own way (custom dumpfile, -C, a framework) and re-running it there
      # is slow and overrides a deliberate setup. A bare zsh has no compdef at all, and
      # completion is simply dead without this.
      printf '(( $+functions[compdef] )) || { autoload -Uz compinit && compinit -u }\n'
      printf '[ -f "$PLUTO_HOME/completions/pluto.zsh" ] && source "$PLUTO_HOME/completions/pluto.zsh"\n'
    else
      printf '[ -f "$PLUTO_HOME/completions/pluto.bash" ] && source "$PLUTO_HOME/completions/pluto.bash"\n'
    fi
    printf '%s\n' "$end"
  } >> "$inter_rc"
  ok "$(rel "$inter_rc") — open a new shell to pick it up"
}

print_shell_block() { # IS_ZSH
  info "add this by hand:"
  dim "export PLUTO_HOME=\"$VAULT\"                    # in .zshenv / .profile"
  dim "export PATH=\"$VAULT/bin:\$PATH\"                # in .zshenv / .profile"
  if [ -n "$1" ]; then
    dim "alias pluto='noglob pluto'                   # in .zshrc"
    dim "source \"$VAULT/completions/pluto.zsh\"        # in .zshrc, after compinit"
  else
    dim "source \"$VAULT/completions/pluto.bash\"       # in .bashrc"
  fi
  return 0
}

phase_cloud() {
  step "PHASE 8 — sync and backup (optional)"
  if ! want "$WANT_CLOUD" "configure a git remote and an encrypted backup?" n; then
    skip "skipped — the vault is still a local git repo"
    SKIPPED_TIERS="$SKIPPED_TIERS cloud"
    return 0
  fi

  info "sync is a private git remote. Real merge semantics; a file-sync daemon over a git"
  info "repo gives you 'file (1).md' and a broken index."
  local remote
  remote="$(ask "git remote URL (empty to skip):" "")"
  if [ -n "$remote" ]; then
    if [ -n "$DRY_RUN" ]; then
      dim "git remote add origin $remote"
    elif git -C "$VAULT" remote | grep -q '^origin$'; then
      skip "origin already set"
    else
      git -C "$VAULT" remote add origin "$remote"
      ok "origin set — push with: git -C $(rel "$VAULT") push -u origin main"
    fi
  fi

  # Detect what is actually mounted rather than hardcoding a provider.
  local found=() d
  for d in "$HOME/Library/CloudStorage"/*; do
    [ -d "$d" ] && found+=("$d")
  done
  [ -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs" ] && \
    found+=("$HOME/Library/Mobile Documents/com~apple~CloudDocs")

  if [ ${#found[@]} -eq 0 ]; then
    skip "no cloud storage found under ~/Library — backup.sh not installed"
    return 0
  fi

  local choice
  choice="$(menu "encrypted backup target:" $(( ${#found[@]} + 1 )) "${found[@]}" "skip")"
  if [ "$choice" = skip ] || [ -z "$choice" ]; then
    skip "no backup target"
    return 0
  fi

  BACKUP_DIR="$choice/pluto-backups"
  BACKUP_LABEL="$(basename "$choice" | sed 's/-.*//')"
  put_code dot-claude/scripts/backup.sh .claude/scripts/backup.sh 755
  ok "backup.sh -> $(rel "$BACKUP_DIR")"
  have age || warn "age is not installed — run: brew install age"
  have gtimeout || have timeout || warn "no timeout(1) — run: brew install coreutils"
}

phase_verify() {
  step "PHASE 9 — verify"
  if [ -n "$DRY_RUN" ]; then skip "dry run — nothing to verify"; return 0; fi
  local fail=0
  check() { # LABEL TEST...
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$label"; else warn "$label — FAILED"; fail=$((fail + 1)); fi
  }
  check "CLAUDE.md"            test -f "$VAULT/CLAUDE.md"
  check "context.md"           test -f "$VAULT/context.md"
  check "launcher executable"  test -x "$VAULT/bin/pluto"
  check "launcher parses"      bash -n "$VAULT/bin/pluto"
  check "hooks parse"          bash -c 'for h in "$1"/.claude/hooks/*.sh; do bash -n "$h" || exit 1; done' _ "$VAULT"
  check "settings.json valid"  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$VAULT/.claude/settings.json"
  check "git repo"             git -C "$VAULT" rev-parse --git-dir
  check "registry reads"       bash -c 'PLUTO="$1"; . "$1/bin/_pluto_registry.sh"; registry | grep -q .' _ "$VAULT"
  check "resolves a project"   bash -c 'PLUTO_HOME="$1" "$1/bin/pluto" --path pluto' _ "$VAULT"
  check "free text dispatches" bash -c 'cd /; PLUTO_DRY_RUN=1 PLUTO_HOME="$1" "$1/bin/pluto" what should I work on' _ "$VAULT"
  check "--names for completion" bash -c 'PLUTO_HOME="$1" "$1/bin/pluto" --names | grep -q .' _ "$VAULT"
  check "bash completion parses"  bash -n "$VAULT/completions/pluto.bash"
  if [ -n "$VENV_PY" ]; then
    check "venv python"        test -x "$VENV_PY"
    check "sqlite-vec imports" "$VENV_PY" -c "import sqlite_vec, mcp"
    # Importing proves the deps resolve; speaking JSON-RPC proves the server actually serves.
    check "mcp server responds"  python3 "$SRC/lib/mcp-smoke.py" "$VENV_PY" "$VAULT"
  fi
  [ "$fail" -eq 0 ] || die "$fail check(s) failed"
}

report() {
  step "done"
  info "vault:     $(rel "$VAULT")"
  info "files:     $INSTALLED written"
  [ -n "$SKIPPED_TIERS" ] && info "skipped:  $SKIPPED_TIERS"
  printf '\n'
  info "next:"
  dim "  1. open a new shell (the PATH and alias are only in new shells)"
  dim "  2. fill in the ## Active block of context.md — nothing works well until it is real"
  dim "  3. add your projects: pluto --create"
  dim "  4. pluto            # pick a project"
  dim "     pluto --status   # what moved lately"
  printf '\n'
}

# ------------------------------------------------------------------------------ main

printf '%s\n' "${C_B}pluto${C_0} — persistent memory for a coding agent"
phase_preflight
adopt_venv
choose_agent
phase_skeleton
phase_content
phase_code
phase_semantic
phase_agent
phase_global
phase_shell
phase_cloud
phase_verify
report
