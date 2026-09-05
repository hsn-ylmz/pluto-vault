# shellcheck shell=bash
# Terminal output and prompting. Sourced by install.sh — no shebang by design.
#
# Every question has a default that is safe to accept blindly, because --yes takes the
# default for all of them and an installer you cannot run unattended is one you cannot test.

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_B=$'\033[1m'; C_DIM=$'\033[2m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
  C_B=""; C_DIM=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi

step()  { printf '\n%s==>%s %s%s%s\n' "$C_G" "$C_0" "$C_B" "$1" "$C_0"; }
info()  { printf '    %s\n' "$1"; }
dim()   { printf '    %s%s%s\n' "$C_DIM" "$1" "$C_0"; }
ok()    { printf '    %s✓%s %s\n' "$C_G" "$C_0" "$1"; }
skip()  { printf '    %s·%s %s\n' "$C_DIM" "$C_0" "$1"; }
warn()  { printf '    %s!%s %s\n' "$C_Y" "$C_0" "$1" >&2; }
die()   { printf '\n%serror:%s %s\n' "$C_R" "$C_0" "$1" >&2; exit "${2:-1}"; }

# Every prompt honours --yes and a non-interactive stdin by taking the default. An installer
# that blocks on a hidden read is one you find out about in CI, or in someone else's terminal.
noninteractive() { [ -n "${ASSUME_YES:-}" ] || [ ! -t 0 ]; }

confirm() { # PROMPT DEFAULT(y|n) -> 0 if yes
  local prompt="$1" def="${2:-n}" reply hint
  case "$def" in y) hint="[Y/n]" ;; *) hint="[y/N]" ;; esac
  if noninteractive; then
    dim "$prompt $hint -> $def (non-interactive)"
    [ "$def" = y ]
    return
  fi
  read -r -p "    $prompt $hint " reply </dev/tty
  [ -n "$reply" ] || reply="$def"
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

ask() { # PROMPT DEFAULT -> answer on stdout
  local prompt="$1" def="${2:-}" reply
  if noninteractive; then
    printf '%s\n' "$def"
    return
  fi
  if [ -n "$def" ]; then
    read -r -p "    $prompt [$def] " reply </dev/tty
  else
    read -r -p "    $prompt " reply </dev/tty
  fi
  printf '%s\n' "${reply:-$def}"
}

# menu LABEL DEFAULT_INDEX ITEM... -> chosen item on stdout (1-based default)
menu() {
  local label="$1" def="$2"; shift 2
  local i=1 choice
  if noninteractive; then
    printf '%s\n' "$(eval "echo \${$def}" 2>/dev/null || printf '%s' "$1")"
    return
  fi
  printf '    %s\n' "$label" >&2
  for item in "$@"; do
    printf '      %s) %s\n' "$i" "$item" >&2
    i=$((i + 1))
  done
  read -r -p "    choice [$def] " choice </dev/tty
  [ -n "$choice" ] || choice="$def"
  case "$choice" in
    ''|*[!0-9]*) printf '%s\n' "$1" ;;
    *) if [ "$choice" -ge 1 ] && [ "$choice" -le $# ]; then
         eval "printf '%s\n' \"\${$choice}\""
       else
         printf '%s\n' "$1"
       fi ;;
  esac
}
