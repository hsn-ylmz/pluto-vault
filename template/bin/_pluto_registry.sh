# shellcheck shell=bash
# Sourced fragment, not a program — no shebang by design.
#
# Shared registry reader. Sourced by bin/pluto and .claude/scripts/refresh_active.sh —
# one definition, so the launcher and the status script can never disagree about
# which projects exist or where they live.
#
# Emits: name<TAB>path<TAB>status
# Source of truth: $PLUTO/projects/*.md frontmatter.

registry() {
  local f name p note
  for f in "${PLUTO:-$HOME/pluto}"/projects/*.md; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .md)"

    # `path:` from the frontmatter block ONLY — a prose body may mention paths too.
    p="$(awk '
      NR==1 && $0=="---" { fm=1; next }
      fm && $0=="---"    { exit }
      fm && /^path:[[:space:]]*/ { sub(/^path:[[:space:]]*/,""); print; exit }
    ' "$f")"
    [ -n "$p" ] || continue

    note="$(awk '/^## Status/{f=1; next} f && NF {print; exit}' "$f")"

    printf '%s\t%s\t%s\n' "$name" "${p/#\~/$HOME}" "$note"
  done
}
