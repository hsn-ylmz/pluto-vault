# Example $PLUTO/bin/pluto-local.sh — copy it there and edit.
#
# Sourced by bin/pluto after every one of its functions is defined and before dispatch, so
# you can call registry(), resolve(), resolve_or_die(), launch(), die(), confirm() and the
# rest. It has no template in the installer, so install.sh never writes over it.
#
# Nothing here is required. Delete the file and pluto behaves exactly as it always did.

# Optional: what --help lists under LOCAL COMMANDS. One "name:description" per line.
pluto_local_commands() {
  cat <<'LIST'
--note:append a line to today's daily log without opening a session
--where:print every registered project directory, one per line
LIST
}

# Optional: a full help section, for commands that need more than a one-line summary.
# Printed after the list above, inside pluto --help.
pluto_local_help() {
  cat <<'HELP'

NOTE
  --note appends one line to today's daily log without starting a session, which is
  the difference between writing something down and deciding to write something down.

      pluto --note deploy went out at 14:02
HELP
}

# Required for commands. Return 0 when you handled it — pluto then exits — and non-zero to
# let pluto carry on with its own dispatch. pluto's own commands are matched first, so you
# cannot shadow --list or --status by accident.
pluto_local_dispatch() {
  case "${1:-}" in
    --note)
      shift
      [ $# -gt 0 ] || die "--note needs something to write" 2
      local log="$PLUTO/daily/$(date +%F).md"
      mkdir -p "$(dirname "$log")"
      [ -f "$log" ] || printf '# %s\n\n' "$(date +%F)" > "$log"
      printf -- '- %s\n' "$*" >> "$log"
      echo "appended to $(tildify "$log")"
      return 0
      ;;
    --where)
      registry | cut -f2
      return 0
      ;;
  esac
  return 1   # not mine
}
