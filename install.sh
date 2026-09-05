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

AGENT_CMD=""        # the CLI the launcher execs; empty means the default, claude
VENV_PY=""          # filled in by the semantic phase; empty means no MCP
VENV_BROKEN=""      # a .venv exists but cannot import what the tier needs
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

# shellcheck disable=SC2088  # the tilde is printed, not expanded — that is the point
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

# curl is not on a stock Ubuntu image, and every probe here was written as if it were.
# python3 is already a hard requirement, so it is the one fetcher guaranteed to exist;
# curl and wget are preferred only because they are faster to start.
http_get() { # URL [TIMEOUT] -> body on stdout
  local url="$1" t="${2:-10}"
  if have curl; then
    curl -fsSL -m "$t" "$url"
  elif have wget; then
    wget -qO- --timeout="$t" "$url"
  else
    python3 - "$url" "$t" <<'PY'
import sys, urllib.request
try:
    with urllib.request.urlopen(sys.argv[1], timeout=float(sys.argv[2])) as r:
        sys.stdout.write(r.read().decode("utf-8", "replace"))
except Exception:
    sys.exit(1)
PY
  fi
}

http_ok() { # URL [TIMEOUT] -> 0 if it answers
  http_get "$1" "${2:-3}" >/dev/null 2>&1
}

# Package managers are loud, and a wall of dpkg progress buries the one line that says what
# pluto actually did. Keep the output, show it only when it turns out to matter.
run_quiet() { # DESCRIPTION COMMAND
  local desc="$1" cmd="$2" log
  log="$(mktemp)"
  printf '    ... %s\n' "$desc"
  if sh -c "$cmd" >"$log" 2>&1; then
    rm -f "$log"
    return 0
  fi
  warn "$desc failed:"
  tail -20 "$log" | sed 's/^/      /' >&2
  rm -f "$log"
  return 1
}

# ---------------------------------------------------------------------------- platform
#
# One detection, one place. Everything that installs something asks these rather than
# guessing at brew, which is how the Linux path came to be missing entirely.

OS=""        # macos | linux | other
PKG=""       # brew | apt | dnf | pacman | zypper | none
PKG_LABEL=""
SUDO=""      # "sudo " when needed and available; empty as root
CAN_ROOT=""  # whether a root-requiring install can run at all

detect_platform() {
  case "$(uname -s)" in
    Darwin) OS=macos ;;
    Linux)  OS=linux ;;
    *)      OS=other ;;
  esac
  # Root needs no sudo, and minimal container images ship without the binary entirely.
  # Gating installs on `have sudo` silently disabled every prompt for the root user.
  if [ "$(id -u)" = 0 ]; then
    SUDO=""; CAN_ROOT=1
  elif have sudo; then
    SUDO="sudo "; CAN_ROOT=1
  else
    SUDO=""; CAN_ROOT=""
  fi

  if have brew;       then PKG=brew;   PKG_LABEL="Homebrew"
  elif have apt-get;  then PKG=apt;    PKG_LABEL="apt"
  elif have dnf;      then PKG=dnf;    PKG_LABEL="dnf"
  elif have pacman;   then PKG=pacman; PKG_LABEL="pacman"
  elif have zypper;   then PKG=zypper; PKG_LABEL="zypper"
  else                     PKG=none;   PKG_LABEL="none"
  fi
}

# Generic name -> the package that actually provides it here. bash 3.2, so: case, not a map.
pkg_for() { # GENERIC
  local py
  case "$1:$PKG" in
    venv:apt)     py="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo 3)"
                  printf 'python%s-venv\n' "$py" ;;
    venv:dnf)     printf 'python3\n' ;;
    venv:pacman)  printf 'python\n' ;;
    venv:zypper)  printf 'python3\n' ;;
    venv:brew)    printf 'python@3.13\n' ;;
    timeout:*)    printf 'coreutils\n' ;;
    nodejs:brew)  printf 'node\n' ;;
    nodejs:apt)   printf 'nodejs npm\n' ;;
    nodejs:dnf)   printf 'nodejs npm\n' ;;
    nodejs:pacman) printf 'nodejs npm\n' ;;
    nodejs:zypper) printf 'nodejs npm\n' ;;
    *)            printf '%s\n' "$1" ;;   # age, fzf: same name everywhere
  esac
}

pkg_install_cmd() { # PACKAGE -> the command a human would type here
  case "$PKG" in
    brew)   printf 'brew install %s\n' "$1" ;;
    apt)    printf '%sapt install -y %s\n' "$SUDO" "$1" ;;
    dnf)    printf '%sdnf install -y %s\n' "$SUDO" "$1" ;;
    pacman) printf '%spacman -S --needed %s\n' "$SUDO" "$1" ;;
    zypper) printf '%szypper install -y %s\n' "$SUDO" "$1" ;;
    *)      printf '\n' ;;
  esac
}

# brew never needs root; everything else here does.
pkg_can_install() {
  [ "$PKG" = brew ] && return 0
  [ "$PKG" = none ] && return 1
  [ -n "$CAN_ROOT" ]
}

# What pluto installed, so the uninstaller can remove exactly that and nothing else.
# Without this record, uninstalling ollama would be a guess about whether it was yours.
MANIFEST_REL=".pluto/installed-by-pluto"
record_installed() { # KIND NAME
  [ -n "$DRY_RUN" ] && return 0
  mkdir -p "$VAULT/.pluto"
  printf '%s\t%s\t%s\n' "$1" "$2" "$(date +%F)" >> "$VAULT/$MANIFEST_REL"
}

# ensure_tool BINARY GENERIC DEFAULT WHY -> 0 if present or installed
ensure_tool() {
  local bin="$1" generic="$2" def="${3:-y}" why="${4:-}" pkg cmd
  have "$bin" && return 0
  pkg="$(pkg_for "$generic")"
  cmd="$(pkg_install_cmd "$pkg")"
  [ -n "$why" ] && warn "$why"
  if [ -z "$cmd" ]; then
    warn "'$bin' is missing and there is no package manager here to install it with"
    return 1
  fi
  info "  $cmd"
  if [ -n "$DRY_RUN" ]; then dim "would run it"; return 1; fi
  if ! pkg_can_install; then
    warn "that needs root, and neither sudo nor a root shell is available here"
    return 1
  fi
  confirm "install it now?" "$def" || return 1
  run_quiet "installing $pkg" "$cmd" || { info "run it yourself, then re-run this installer"; return 1; }
  have "$bin" || return 1
  record_installed "$PKG" "$pkg"
}

# macOS without Homebrew can install almost none of the optional pieces. Say so once, and
# offer the documented remedy rather than repeating "brew install ..." at a machine with
# no brew on it.
offer_homebrew() {
  [ "$OS" = macos ] || return 1
  have brew && return 0
  warn "Homebrew is not installed, and it is how macOS gets age, coreutils, fzf and ollama"
  info "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/brew/HEAD/install.sh)\""
  [ -n "$DRY_RUN" ] && return 1
  confirm "install Homebrew now? (fetches and runs a script from the network)" n || return 1
  have curl || { warn "the Homebrew installer needs curl, which is missing"; return 1; }
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/brew/HEAD/install.sh)" || return 1
  # A fresh install is not on PATH in this shell yet.
  for c in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$c" ] && eval "$("$c" shellenv)" && break
  done
  detect_platform
  have brew || return 1
  record_installed manual homebrew
}

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

# Results go in globals and the function is called directly, NEVER as `$(pick_python)`:
# a command substitution runs in a subshell, so the diagnosis would be discarded and every
# failure would be reported as whichever cause happens to be checked last.
PY_CHOSEN=""          # the interpreter, empty if none qualified
PY_PROBLEM=""         # venv | extensions — why none qualified
PY_VENV_CANDIDATE=""  # a python that loads extensions but cannot build a venv

pick_python() {
  local c saw_ext=""
  PY_CHOSEN=""; PY_PROBLEM=""; PY_VENV_CANDIDATE=""
  for c in "$(brew --prefix 2>/dev/null)/bin/python3" python3.13 python3.12 python3.11 python3; do
    [ -n "$c" ] || continue
    have "$c" || continue
    py_loads_extensions "$c" || continue
    saw_ext=1
    if py_can_venv "$c"; then PY_CHOSEN="$(command -v "$c")"; return 0; fi
    PY_VENV_CANDIDATE="$(command -v "$c")"
  done
  if [ -n "$saw_ext" ]; then PY_PROBLEM=venv; else PY_PROBLEM=extensions; fi
  return 1
}

# The exact command for this machine, not a generic "install the venv package".
venv_fix_hint() { # PYTHON (unused; kept for symmetry with the platform helpers)
  local cmd
  cmd="$(pkg_install_cmd "$(pkg_for venv)")"
  [ -n "$cmd" ] && printf '%s\n' "$cmd" || printf 'install the venv/ensurepip module\n'
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

  detect_platform
  case "$OS" in
    macos) ok "macOS ($(uname -m))" ;;
    linux) ok "Linux ($(uname -m)) — backup.sh is macOS-only; everything else works here" ;;
    other) warn "$(uname -s) is untested; the core is portable shell and will probably work" ;;
  esac
  if [ "$PKG" = none ]; then
    warn "no supported package manager found — optional extras must be installed by hand"
    [ "$OS" = macos ] && offer_homebrew || true
  elif pkg_can_install; then
    ok "package manager: $PKG_LABEL$([ "$(id -u)" = 0 ] && printf ' (running as root)')"
  else
    ok "package manager: $PKG_LABEL"
    warn "not root and no sudo — anything needing a package install will be printed, not run"
  fi

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
# A venv is healthy when it can import what the tier needs, not when its python exists.
# An interrupted `python3 -m venv` leaves the interpreter behind with no packages in it,
# and adopting that means the tier reports itself installed and then fails verification.
venv_healthy() { # PYTHON
  [ -x "$1" ] || return 1
  "$1" -c "import sqlite_vec, mcp" >/dev/null 2>&1
}

adopt_venv() {
  local p="$VAULT/.venv/bin/python"
  [ -e "$VAULT/.venv" ] || return 0
  step "existing install"
  VENV_PY="$p"
  if venv_healthy "$p"; then
    ok "venv adopted: $(rel "$p")"
  else
    VENV_BROKEN=1
    warn "the virtualenv at $(rel "$VAULT/.venv") is incomplete"
    info "usually an install that was interrupted partway. It will be rebuilt."
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

  if [ -n "$VENV_PY" ] && [ -z "$VENV_BROKEN" ] && [ "$WANT_SEMANTIC" != yes ]; then
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
  py=""
  if pick_python; then py="$PY_CHOSEN"; fi
  if [ -z "$py" ]; then
    if [ "$PY_PROBLEM" = venv ]; then
      fix="$(venv_fix_hint "${PY_VENV_CANDIDATE:-python3}")"
      warn "python3 is here but cannot create a virtualenv (ensurepip is missing)"
      info "Debian and Ubuntu split that into its own package. Fix with:"
      info "  $fix"
      if [ -z "$DRY_RUN" ] && ! pkg_can_install; then
        warn "that needs root, and neither sudo nor a root shell is available here"
      elif [ -z "$DRY_RUN" ] && confirm "run that now?" y; then
        if run_quiet "installing $(pkg_for venv)" "$fix"; then
          record_installed "$PKG" "$(pkg_for venv)"
          if pick_python; then py="$PY_CHOSEN"; fi
        else
          warn "that failed — run it yourself, then: ./install.sh --semantic"
        fi
      fi
    else
      warn "no python3 here can load sqlite extensions, which sqlite-vec needs"
      local pycmd
      pycmd="$(pkg_install_cmd "$(pkg_for venv)")"
      if [ -n "$pycmd" ]; then
        info "install a python3 that has them:"
        info "  $pycmd"
      else
        info "install a python3 built with loadable sqlite extension support"
      fi
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

  # Only now, with a working interpreter in hand, is it safe to throw the broken one away:
  # .venv is disposable and gitignored, but deleting it before we can rebuild would leave
  # the script shebangs pointing at nothing.
  if [ -n "$VENV_BROKEN" ]; then
    rm -rf "$VAULT/.venv"
    VENV_BROKEN=""
    info "removed the incomplete virtualenv"
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
     || ! "$VENV_PY" -m pip install --quiet mcp sqlite-vec >/dev/null 2>&1; then
    warn "pip could not install mcp and sqlite-vec (offline, or a proxy in the way)"
    info "retry later with: ./install.sh --semantic"
    VENV_PY=""
    SKIPPED_TIERS="$SKIPPED_TIERS semantic"
    return 0
  fi
  ok "mcp + sqlite-vec installed"

  if ! have ollama && ! http_ok "${PLUTO_OLLAMA_URL:-http://localhost:11434}/api/tags"; then
    install_ollama || {
      warn "no ollama — index and search will not work until it is installed"
      info "already running one elsewhere? export PLUTO_OLLAMA_URL=http://host:11434"
      SKIPPED_TIERS="$SKIPPED_TIERS ollama"
      return 0
    }
  fi
  ok "ollama present"

  # The Linux installer sets up a systemd unit; inside a container, or on a box without
  # systemd, nothing is listening yet and every later step would fail on a connection
  # refused that says nothing about the cause.
  if ! http_ok "${PLUTO_OLLAMA_URL:-http://localhost:11434}/api/tags"; then
    if have systemctl && systemctl start ollama >/dev/null 2>&1; then
      sleep 2
    fi
  fi
  # No systemd (containers, WSL, a plain macOS shell) means the unit the installer wrote is
  # never started, and everything below fails on a connection refused. Offer to run it here.
  # This is a foreground daemon parked in the background: it dies with the machine, which is
  # said plainly rather than left to be discovered after the next reboot.
  if [ -z "$DRY_RUN" ] && have ollama \
     && ! http_ok "${PLUTO_OLLAMA_URL:-http://localhost:11434}/api/tags" \
     && case "${PLUTO_OLLAMA_URL:-http://localhost:11434}" in *localhost*|*127.0.0.1*) true ;; *) false ;; esac
  then
    warn "ollama is installed but nothing is listening"
    info "no service manager started it, so it has to be run directly"
    if confirm "start 'ollama serve' in the background now?" y; then
      mkdir -p "$VAULT/.pluto"
      nohup ollama serve >"$VAULT/.pluto/ollama.log" 2>&1 &
      local waited=0
      while [ "$waited" -lt 20 ]; do
        http_ok "${PLUTO_OLLAMA_URL:-http://localhost:11434}/api/tags" && break
        sleep 1
        waited=$((waited + 1))
      done
      if http_ok "${PLUTO_OLLAMA_URL:-http://localhost:11434}/api/tags"; then
        ok "ollama serving (log: $(rel "$VAULT/.pluto/ollama.log"))"
        info "it stops when this machine does; start it again with: ollama serve"
      else
        warn "it did not come up in 20s — see $(rel "$VAULT/.pluto/ollama.log")"
      fi
    fi
  fi

  local ollama_url="${PLUTO_OLLAMA_URL:-http://localhost:11434}"
  if ! http_ok "$ollama_url/api/tags"; then
    warn "ollama not responding at $ollama_url"
    info "start it (\`ollama serve\`, or open the app), then run:"
    info "  $VENV_PY $VAULT/.claude/scripts/pluto_index.py"
    return 0
  fi

  if http_get "$ollama_url/api/tags" 5 2>/dev/null | grep -q "nomic-embed-text-v2-moe"; then
    skip "embedding model already pulled"
  elif have ollama; then
    info "pulling nomic-embed-text-v2-moe (~1 GB)"
    ollama pull nomic-embed-text-v2-moe
    record_installed ollama-model nomic-embed-text-v2-moe
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

  # The launcher execs this. Getting it wrong is not fatal here, but discovering it at the
  # first `pluto something` is a worse place to find out.
  case "$AGENT" in
    claude-code) AGENT_CMD=claude ;;
    codex)       AGENT_CMD=codex ;;
    cursor)      AGENT_CMD=cursor-agent ;;
    none)        AGENT_CMD="" ;;
    other)       AGENT_CMD="$(ask "command the launcher should run:" claude)" ;;
  esac
  [ -n "$AGENT_CMD" ] || return 0

  if have "$AGENT_CMD"; then
    ok "launcher will run: $AGENT_CMD ($(command -v "$AGENT_CMD"))"
    return 0
  fi

  warn "'$AGENT_CMD' is not on your PATH"
  if [ "$AGENT_CMD" = claude ] && install_claude_code; then
    ok "launcher will run: claude ($(command -v claude))"
    return 0
  fi
  [ "$AGENT_CMD" = claude ] && info "install it later: https://claude.com/claude-code"
  info "everything except starting a session still works: --list, --status, --create ..."
  info "already have it under another name? export PLUTO_AGENT=<command>"
}

# Offered rather than assumed: the agent is a separate program with its own login and its
# own update channel, and plenty of people already have it somewhere pluto cannot see.
install_claude_code() {
  [ -n "$DRY_RUN" ] && return 1
  if ! have npm; then
    info "Claude Code installs through npm, which is not here either."
    ensure_tool npm nodejs y "Node.js provides npm" || return 1
  fi
  info "  npm install -g @anthropic-ai/claude-code"
  # Installing the binary is all this does. Signing in is a separate, interactive step that
  # belongs to you, and the installer never touches credentials.
  confirm "install Claude Code now? (installs the CLI only; you sign in yourself)" y || return 1
  run_quiet "installing @anthropic-ai/claude-code" "npm install -g @anthropic-ai/claude-code" || return 1
  have claude || return 1
  record_installed npm @anthropic-ai/claude-code
}

# Package managers differ, and so does what counts as consent. brew and apt verify what
# they install; Ollama's Linux instructions are a script piped from the network into a
# shell, which is a different proposition, so that one defaults to no and prints the
# command either way.
install_ollama() {
  case "$OS" in
    macos)
      if ! have brew; then
        offer_homebrew || {
          info "or install Ollama directly: https://ollama.com/download"
          return 1
        }
      fi
      confirm "ollama is not installed. install it with brew?" y || return 1
      run_quiet "installing ollama" "brew install ollama" || return 1
      record_installed brew ollama
      ;;
    linux)
      # Ollama ships no apt/dnf package; the documented path is this script. It is a
      # network script piped into a shell, so it defaults to no and is printed either way.
      info "Ollama's documented Linux install is a script fetched from the network:"
      dim "  curl -fsSL https://ollama.com/install.sh | sh"
      confirm "run it?" y || return 1
      # Ollama's installer has its own dependencies and reports them one at a time, so
      # they are satisfied up front rather than discovered across three failed attempts:
      # it shells out to curl, and unpacks a zstd-compressed archive.
      local dep
      for dep in curl tar zstd; do
        have "$dep" && continue
        ensure_tool "$dep" "$dep" y "Ollama's installer needs $dep" || return 1
      done
      run_quiet "installing ollama" "curl -fsSL https://ollama.com/install.sh | sh" || return 1
      record_installed script ollama
      ;;
    *)
      info "install ollama from https://ollama.com/download, then re-run with --semantic"
      return 1
      ;;
  esac
  have ollama
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
  # shellcheck disable=SC2088  # display string
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

# Which file a line goes in is not cosmetic; it decides whether `pluto` exists at all.
#
#   zsh   .zshenv  every zsh, including scripts and ssh          <- env belongs here
#         .zshrc   interactive only                              <- alias, completion
#   bash  .profile login shells only
#         .bashrc  interactive non-login shells                   <- a plain terminal
#
# bash is the awkward one: neither file covers both cases, and Ubuntu's stock .bashrc does
# not source .profile. Putting the environment only in .profile leaves `pluto: not found`
# in an ordinary terminal, so bash gets it in both places.
emit_env_block() {
  printf '\n%s\n' "# >>> pluto >>>"
  printf 'export PLUTO_HOME="%s"\n' "$VAULT"
  printf 'case ":$PATH:" in *":%s/bin:"*) ;; *) export PATH="%s/bin:$PATH" ;; esac\n' "$VAULT" "$VAULT"
  # Only when it differs from the default, so the common case leaves no noise behind.
  if [ -n "$AGENT_CMD" ] && [ "$AGENT_CMD" != claude ]; then
    printf 'export PLUTO_AGENT="%s"\n' "$AGENT_CMD"
  fi
  printf '%s\n' "# <<< pluto <<<"
}

emit_interactive_block() { # IS_ZSH
  printf '\n%s\n' "# >>> pluto (interactive) >>>"
  if [ -n "$1" ]; then
    printf '# Free text goes straight to your agent: `pluto how do I clean my mac safely?`\n'
    printf '# noglob stops zsh expanding the ? and * before pluto ever sees them.\n'
    printf "alias pluto='noglob pluto'\n"
    printf '(( $+functions[compdef] )) || { autoload -Uz compinit && compinit -u }\n'
    printf '[ -f "$PLUTO_HOME/completions/pluto.zsh" ] && source "$PLUTO_HOME/completions/pluto.zsh"\n'
  else
    printf '[ -f "$PLUTO_HOME/completions/pluto.bash" ] && source "$PLUTO_HOME/completions/pluto.bash"\n'
  fi
  printf '%s\n' "# <<< pluto (interactive) <<<"
}

append_block() { # FILE MARKER LABEL EMITTER [ARG]
  local f="$1" marker="$2" label="$3" fn="$4" arg="${5:-}"
  if [ -f "$f" ] && grep -q "$marker" "$f" 2>/dev/null; then
    skip "$(rel "$f") already has the $label block"
    return 0
  fi
  "$fn" "$arg" >> "$f"
  ok "$(rel "$f")  ($label)"
}

phase_shell() {
  step "PHASE 7 — shell"
  local is_zsh="" env_files inter_file f
  case "${SHELL:-}" in
    */zsh)  is_zsh=1; env_files="$HOME/.zshenv";              inter_file="$HOME/.zshrc" ;;
    */bash)          env_files="$HOME/.profile $HOME/.bashrc"; inter_file="$HOME/.bashrc" ;;
    *)               env_files="$HOME/.profile";               inter_file="" ;;
  esac

  if [ "$WANT_SHELL" = no ]; then
    skip "not touching any rc file"
    print_shell_block "$is_zsh"
    return 0
  fi

  info "PLUTO_HOME and PATH -> $(for f in $env_files; do printf '%s ' "$(rel "$f")"; done)"
  [ -n "$inter_file" ] && info "completion$([ -n "$is_zsh" ] && printf ' and the noglob alias') -> $(rel "$inter_file")"

  if ! confirm "append pluto blocks?" y; then
    skip "declined"
    print_shell_block "$is_zsh"
    return 0
  fi
  if [ -n "$DRY_RUN" ]; then
    for f in $env_files; do dim "append env block to $(rel "$f")"; done
    [ -n "$inter_file" ] && dim "append interactive block to $(rel "$inter_file")"
    return 0
  fi

  for f in $env_files; do
    append_block "$f" "# >>> pluto >>>" env emit_env_block
  done
  if [ -n "$inter_file" ]; then
    append_block "$inter_file" "# >>> pluto (interactive) >>>" completion emit_interactive_block "$is_zsh"
  fi
  info "open a new shell to pick it up"
}

# Its own step: fzf has nothing to do with rc files, and declining those should not
# silently decide this too.
phase_extras() {
  have fzf && return 0
  step "PHASE 7b — optional extras"
  info "fzf turns bare 'pluto' into a fuzzy picker; without it you get a numbered menu"
  # A no by default: the launcher degrades gracefully, so this is a convenience rather
  # than something to install on someone's behalf.
  ensure_tool fzf fzf n || true
}

print_shell_block() { # IS_ZSH
  info "add this by hand:"
  dim "export PLUTO_HOME=\"$VAULT\""
  dim "export PATH=\"$VAULT/bin:\$PATH\""
  if [ -n "$1" ]; then
    dim "  ^ in ~/.zshenv, so every zsh sees it"
    dim "alias pluto='noglob pluto'                   # in .zshrc"
    dim "source \"$VAULT/completions/pluto.zsh\"        # in .zshrc, after compinit"
  else
    dim "  ^ in BOTH ~/.profile (login) and ~/.bashrc (interactive)"
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
  ensure_tool age age y "backup.sh needs age to encrypt the bundle before it leaves the machine" || true
  if ! have gtimeout && ! have timeout; then
    if [ "$OS" = macos ]; then
      ensure_tool gtimeout timeout y "backup.sh probes the cloud mount under a timeout" || true
    else
      ensure_tool timeout timeout y "backup.sh probes the cloud mount under a timeout" || true
    fi
  fi
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
  case " $SKIPPED_TIERS " in
    *" semantic "*) VENV_PY="" ;;   # not installed, so nothing to check
  esac
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
  if [ -n "$AGENT_CMD" ] && ! have "$AGENT_CMD"; then
    warn "'$AGENT_CMD' is still not installed — pluto NAME and free text will not start"
  elif [ -n "$AGENT_CMD" ]; then
    dim "  sign in to $AGENT_CMD once before the first session; pluto never touches credentials"
  fi
  if have ollama && ! http_ok "${PLUTO_OLLAMA_URL:-http://localhost:11434}/api/tags"; then
    dim "  ollama is installed but not serving yet:  ollama serve"
  fi
  [ -n "$SKIPPED_TIERS" ] && info "skipped:  $SKIPPED_TIERS"
  printf '\n'
  info "next:"
  dim "  1. open a new shell (the PATH and alias are only in new shells)"
  dim "  2. fill in the ## Active block of context.md — nothing works well until it is real"
  dim "  3. add your projects: pluto --create"
  dim "  4. pluto            # pick a project"
  dim "     pluto --status   # what moved lately"
  printf '\n'
  dim "  to undo all of this later:  $(rel "$SRC")/uninstall.sh"
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
phase_extras
phase_cloud
phase_verify
report
