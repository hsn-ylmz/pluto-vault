#!/bin/bash
# Prints the current state of everything in the registry, for pasting into
# context.md's ## Active.
#
# Deliberately does NOT write context.md. Git state and mtimes tell you when something
# moved, never what you are trying to do with it — and the second half is what makes
# the file worth injecting. Paste the output, then add the intent by hand.
#
# Projects come from $PLUTO/projects/*.md, the same registry the `pluto` launcher uses.
# There is no second list of paths to keep in sync.

set -u
PLUTO="${PLUTO_HOME:-$HOME/pluto}"
. "$PLUTO/bin/_pluto_registry.sh"

# NOTE is the status column. It is read to consume the third field — the intent half
# belongs in context.md, written by hand, not echoed back from the registry.
# shellcheck disable=SC2034
while IFS=$'\t' read -r NAME DIR NOTE; do
  if [ ! -d "$DIR" ]; then
    printf -- '- %s — MISSING (%s)\n' "$NAME" "$DIR"
    continue
  fi

  if [ -d "$DIR/.git" ]; then
    BRANCH="$(git -C "$DIR" branch --show-current)"
    [ -n "$BRANCH" ] || BRANCH="detached @ $(git -C "$DIR" rev-parse --short HEAD)"

    WHEN="$(git -C "$DIR" log -1 --format=%cr 2>/dev/null)" || WHEN="no commits"
    SUBJ="$(git -C "$DIR" log -1 --format=%s 2>/dev/null | cut -c1-60)"

    DIRTY=""
    [ -n "$(git -C "$DIR" status --porcelain 2>/dev/null)" ] && DIRTY=", uncommitted changes"

    # Note: `A && B || C` would misfire here — B's group returns non-zero when the
    # unpushed count is 0, which is the common case. Use an explicit if.
    UNPUSHED=""
    if [ -z "$(git -C "$DIR" remote)" ]; then
      UNPUSHED=", no remote"
    elif git -C "$DIR" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
      N="$(git -C "$DIR" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
      [ "${N:-0}" -gt 0 ] && UNPUSHED=", $N unpushed"
    else
      UNPUSHED=", no upstream set"
    fi

    printf -- '- %s — %s%s%s, last commit %s (%s)\n' \
      "$NAME" "$BRANCH" "$DIRTY" "$UNPUSHED" "$WHEN" "$SUBJ"
  else
    # Not under git; mtime is the only "when did this move" signal available.
    # build/ is excluded so a rebuild doesn't mask the source file that actually changed.
    NEWEST="$(find "$DIR" -type f -not -path '*/.*' -not -path '*/build/*' \
                -exec stat -f '%m %N' {} + 2>/dev/null | sort -rn | head -1)"
    TS="${NEWEST%% *}"
    FILE="${NEWEST#* }"
    printf -- '- %s — not under git, last touched %s (%s)\n' \
      "$NAME" "$(date -r "${TS:-0}" '+%Y-%m-%d')" "$(basename "${FILE:-none}")"
  fi
done < <(registry)
