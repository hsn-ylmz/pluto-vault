#!/bin/bash
# pluto uninstaller — undoes what install.sh did, in the order that is safest to stop at.
#
# Two rules shape this script:
#
#   1. Packages are removed only if pluto installed them. install.sh records what it
#      installed in .pluto/installed-by-pluto; anything absent from that file was yours
#      before pluto existed and is left alone. Guessing here means removing someone's
#      ollama because a vault happened to use it.
#
#   2. Your writing is the last thing touched, is never part of a default run, and is
#      offered a backup first. Code can be reinstalled from this repo; notes cannot.
#
# Targets bash 3.2, like everything else here.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/ui.sh
. "$SRC/lib/ui.sh"

VAULT="${PLUTO_HOME:-$HOME/pluto}"
ASSUME_YES=""
DRY_RUN=""
WANT_NOTES="ask"
WANT_PACKAGES="ask"
MANIFEST_REL=".pluto/installed-by-pluto"
REMOVED=0

usage() {
  cat <<EOF
pluto uninstaller

USAGE
  ./uninstall.sh [options]

OPTIONS
  --vault PATH      which vault to remove       (default: \$PLUTO_HOME, else ~/pluto)
  --everything      also delete your notes, after confirming and offering a backup
  --keep-packages   do not touch anything installed through a package manager
  --keep-notes      never ask about notes (the default is to ask, and default to no)
  -y, --yes         take the default for every prompt. The default for notes is NO.
  -n, --dry-run     print what would be removed, remove nothing
  -h, --help        this text

WHAT IT REMOVES, in order
  1. the pluto blocks in your shell rc files
  2. the global layer in ~/.claude (hook, /pref, the SessionStart entry, the MCP server)
  3. generated state in the vault: .venv, the embedding index, settings.local.json
  4. installed code: bin/pluto, bin/_pluto_registry.sh, .claude/, completions/
     (bin/pluto-local.sh is yours and is kept)
  5. packages that pluto installed, and only those, read from $MANIFEST_REL
  6. your notes and markdown — only with --everything or an explicit yes

Stopping after any step leaves a coherent machine. Step 4 without step 6 leaves a
directory of markdown you can open in any editor, which is the whole point of the format.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --vault)         shift; [ $# -gt 0 ] || die "--vault needs a path" 2; VAULT="$1" ;;
    --everything)    WANT_NOTES=yes ;;
    --keep-notes)    WANT_NOTES=no ;;
    --keep-packages) WANT_PACKAGES=no ;;
    -y|--yes)        ASSUME_YES=1 ;;
    -n|--dry-run)    DRY_RUN=1 ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "unknown option '$1' (try --help)" 2 ;;
  esac
  shift
done

VAULT="${VAULT/#\~/$HOME}"

# shellcheck disable=SC2088  # the tilde is printed, not expanded — that is the point
rel() { case "$1" in "$HOME"/*) printf '~/%s\n' "${1#"$HOME"/}" ;; *) printf '%s\n' "$1" ;; esac; }

# Same rule as install.sh: root needs no sudo, and minimal images ship without the binary.
# Hardcoding it here made every package removal fail for the root user.
if [ "$(id -u)" = 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo "
else
  SUDO=""
fi

run_quiet() { # DESCRIPTION COMMAND
  local desc="$1" cmd="$2" log
  log="$(mktemp)"
  if sh -c "$cmd" >"$log" 2>&1; then rm -f "$log"; return 0; fi
  warn "$desc failed:"
  tail -12 "$log" | sed 's/^/      /' >&2
  rm -f "$log"
  return 1
}

gone() { # PATH
  if [ ! -e "$1" ]; then return 0; fi
  if [ -n "$DRY_RUN" ]; then dim "would remove $(rel "$1")"; return 0; fi
  rm -rf "$1"
  ok "removed $(rel "$1")"
  REMOVED=$((REMOVED + 1))
}

# Delete only between our markers, so a file that also holds a hundred lines of your own
# configuration comes back exactly as it was.
strip_block() { # FILE START END
  local f="$1" start="$2" end="$3"
  [ -f "$f" ] || return 0
  grep -q "$start" "$f" 2>/dev/null || return 0
  if [ -n "$DRY_RUN" ]; then dim "would strip the $start block from $(rel "$f")"; return 0; fi
  cp "$f" "$f.pluto-backup"
  awk -v s="$start" -v e="$end" '
    index($0, s) { skip = 1 }
    !skip        { print }
    index($0, e) { skip = 0 }
  ' "$f.pluto-backup" > "$f"
  ok "$(rel "$f") — block removed (previous file kept as $(basename "$f").pluto-backup)"
  REMOVED=$((REMOVED + 1))
}

# ------------------------------------------------------------------------------- plan

step "what will be removed"
info "vault: $(rel "$VAULT")"
if [ ! -d "$VAULT" ]; then
  warn "no vault at $(rel "$VAULT") — shell blocks and the global layer will still be checked"
fi
[ -n "$DRY_RUN" ] && warn "dry run — nothing will be removed"

MANIFEST="$VAULT/$MANIFEST_REL"
if [ -f "$MANIFEST" ]; then
  info "packages pluto installed on this machine:"
  while IFS=$'\t' read -r kind name when; do
    [ -n "${name:-}" ] || continue
    printf '      %s (%s, %s)\n' "$name" "$kind" "$when"
  done < "$MANIFEST"
else
  info "no install manifest — no packages will be touched"
fi

NOTE_COUNT=0
if [ -d "$VAULT" ]; then
  NOTE_COUNT=$(find "$VAULT" -name '*.md' -not -path '*/.git/*' -not -path '*/.venv/*' 2>/dev/null | wc -l | tr -d ' ')
  info "markdown files in the vault: $NOTE_COUNT"
fi

if ! confirm "continue?" y; then
  echo "cancelled"
  exit 0
fi

# --------------------------------------------------------------------------- 1. shell

step "1. shell rc files"
for f in "$HOME/.zshenv" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.bashrc" "$HOME/.bash_profile"; do
  strip_block "$f" "# >>> pluto >>>" "# <<< pluto <<<"
  strip_block "$f" "# >>> pluto (interactive) >>>" "# <<< pluto (interactive) <<<"
done

# --------------------------------------------------------------------------- 2. global

step "2. global layer in ~/.claude"
gone "$HOME/.claude/hooks/pluto-global-start.sh"
gone "$HOME/.claude/commands/pref.md"

if [ -f "$HOME/.claude/settings.json" ]; then
  if [ -n "$DRY_RUN" ]; then
    dim "would remove the pluto SessionStart entry from ~/.claude/settings.json"
  else
    # Remove only our entry. Everything else in that file belongs to the user, and
    # rewriting it wholesale is how this kind of uninstaller earns its reputation.
    # shellcheck disable=SC2088  # display string
    python3 - <<'PY' && ok "~/.claude/settings.json — pluto SessionStart entry removed" || warn "could not edit ~/.claude/settings.json"
import json, pathlib, sys
p = pathlib.Path.home() / ".claude" / "settings.json"
try:
    data = json.loads(p.read_text())
except Exception:
    sys.exit(1)
hooks = data.get("hooks", {})
starts = hooks.get("SessionStart", [])
kept = [e for e in starts if "pluto-global-start.sh" not in json.dumps(e)]
if len(kept) == len(starts):
    sys.exit(0)
if kept:
    hooks["SessionStart"] = kept
else:
    hooks.pop("SessionStart", None)
if not hooks:
    data.pop("hooks", None)
p.write_text(json.dumps(data, indent=2) + "\n")
PY
  fi
fi

if command -v claude >/dev/null 2>&1; then
  if [ -n "$DRY_RUN" ]; then
    dim "would run: claude mcp remove pluto -s user"
  elif claude mcp remove pluto -s user >/dev/null 2>&1; then
    ok "global MCP registration removed"
  fi
fi

cfg="$HOME/.cursor/mcp.json"
if [ -f "$cfg" ] && [ -n "$DRY_RUN" ]; then
  dim "would remove the pluto server from $(rel "$cfg")"
elif [ -f "$cfg" ]; then
  CFG="$cfg" python3 - <<'PY' && ok "$(rel "$cfg") — pluto server removed" || true
import json, os, pathlib, sys
p = pathlib.Path(os.environ["CFG"])
try:
    data = json.loads(p.read_text())
except Exception:
    sys.exit(1)
servers = data.get("mcpServers", {})
if "pluto" not in servers:
    sys.exit(1)
servers.pop("pluto")
p.write_text(json.dumps(data, indent=2) + "\n")
PY
fi

# ------------------------------------------------------------------------ 3. generated

step "3. generated state in the vault"
gone "$VAULT/.venv"
gone "$VAULT/.pluto/index.db"
gone "$VAULT/.claude/settings.local.json"
gone "$VAULT/.claude/hooks/.state"

# ----------------------------------------------------------------------------- 4. code

step "4. installed code in the vault"
# Not `rm -rf bin`: bin/pluto-local.sh is yours, has no template, and is exactly the file
# someone put work into. Remove what was installed and say what was left.
gone "$VAULT/bin/pluto"
gone "$VAULT/bin/_pluto_registry.sh"
if [ -f "$VAULT/bin/pluto-local.sh" ]; then
  info "kept $(rel "$VAULT/bin/pluto-local.sh") — your own commands, never installed by pluto"
elif [ -d "$VAULT/bin" ] && [ -z "$(ls -A "$VAULT/bin" 2>/dev/null)" ]; then
  gone "$VAULT/bin"
fi
gone "$VAULT/completions"
gone "$VAULT/.claude"
gone "$VAULT/.mcp.json"

# ------------------------------------------------------------------------- 5. packages

step "5. packages pluto installed"
if [ "$WANT_PACKAGES" = no ]; then
  skip "--keep-packages"
elif [ ! -f "$MANIFEST" ]; then
  skip "nothing recorded, so nothing is assumed"
else
  # Reverse install order. Removing nodejs before the npm package it installed destroys the
  # npm that would have removed it, leaving an orphaned binary behind — which is exactly
  # what happened the first time this ran.
  while IFS=$'\t' read -r kind name when; do
    [ -n "${name:-}" ] || continue
    cmd=""
    case "$kind" in
      brew)         cmd="brew uninstall $name" ;;
      apt)          cmd="${SUDO}apt remove -y $name" ;;
      dnf)          cmd="${SUDO}dnf remove -y $name" ;;
      pacman)       cmd="${SUDO}pacman -Rs --noconfirm $name" ;;
      zypper)       cmd="${SUDO}zypper remove -y $name" ;;
      ollama-model) cmd="ollama rm $name" ;;
      npm)          cmd="npm uninstall -g $name" ;;
      script)
        if [ "$name" = ollama ]; then
          info "ollama was installed by its own script; the documented removal is:"
          dim "  ${SUDO}systemctl stop ollama && ${SUDO}systemctl disable ollama"
          dim "  ${SUDO}rm /etc/systemd/system/ollama.service"
          dim "  ${SUDO}rm \$(command -v ollama)"
          dim "  ${SUDO}rm -r /usr/share/ollama && ${SUDO}userdel ollama && ${SUDO}groupdel ollama"
          confirm "run that now?" y && {
            ${SUDO}systemctl stop ollama >/dev/null 2>&1 || true
            ${SUDO}systemctl disable ollama >/dev/null 2>&1 || true
            ${SUDO}rm -f /etc/systemd/system/ollama.service || true
            ${SUDO}rm -f "$(command -v ollama 2>/dev/null || echo /usr/local/bin/ollama)" || true
            ${SUDO}rm -rf /usr/share/ollama || true
            ${SUDO}userdel ollama >/dev/null 2>&1 || true
            ${SUDO}groupdel ollama >/dev/null 2>&1 || true
            ok "ollama removed"
          }
        fi
        continue ;;
      manual)
        info "$name was installed manually and is left alone (removing it is your call)"
        continue ;;
    esac
    [ -n "$cmd" ] || continue
    info "  $cmd"
    if [ -n "$DRY_RUN" ]; then continue; fi
    confirm "remove $name?" y && { run_quiet "removing $name" "$cmd" && ok "$name removed" || true; }
  done < <(awk '{ a[NR] = $0 } END { for (i = NR; i > 0; i--) print a[i] }' "$MANIFEST")
fi

# -------------------------------------------------------------------------- 6. content

step "6. your notes"
if [ ! -d "$VAULT" ]; then
  skip "no vault directory"
elif [ "$WANT_NOTES" = no ]; then
  skip "--keep-notes"
else
  info "$NOTE_COUNT markdown files, plus the git history of every one of them."
  info "Code can be reinstalled from this repo. This cannot."
  if [ "$WANT_NOTES" = yes ] || confirm "delete your notes as well?" n; then
    if [ -z "$DRY_RUN" ] && [ -d "$VAULT/.git" ]; then
      bundle="$HOME/pluto-final-$(date +%F).bundle"
      if confirm "write a git bundle of everything to $(rel "$bundle") first?" y; then
        git -C "$VAULT" bundle create "$bundle" --all >/dev/null 2>&1 \
          && ok "$(rel "$bundle") — restore with: git clone $(rel "$bundle") pluto" \
          || warn "could not write the bundle; stopping rather than deleting unbacked notes"
        [ -f "$bundle" ] || exit 1
      fi
    fi
    gone "$VAULT"
  else
    skip "notes kept at $(rel "$VAULT")"
  fi
fi

step "done"
if [ -n "$DRY_RUN" ]; then
  info "dry run — nothing was removed"
else
  info "$REMOVED item(s) removed"
fi
[ -d "$VAULT" ] && info "your notes are still at $(rel "$VAULT")"
info "open a new shell; the old one still has PLUTO_HOME and PATH set"
