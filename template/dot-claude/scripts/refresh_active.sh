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

# BSD and GNU disagree about both of the tools this script leans on. macOS ships BSD, Linux
# ships GNU, and the flags are not merely different spellings — `stat -f` on GNU means
# "filesystem", so it fails rather than misbehaving, and the mtime column silently comes out
# empty. Probe once, then use the right pair.
# The stat flags have to be plain variables, not a wrapper function: `find -exec` runs a
# real binary and cannot see shell functions.
if stat -f '%m' . >/dev/null 2>&1; then
  STAT_FLAG=-f; STAT_FMT='%m %N'                # BSD / macOS
  date_ymd() { date -r "$1" '+%Y-%m-%d'; }
else
  STAT_FLAG=-c; STAT_FMT='%Y %n'                # GNU / Linux
  date_ymd() { date -d "@$1" '+%Y-%m-%d'; }
fi

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
                -exec stat "$STAT_FLAG" "$STAT_FMT" {} + 2>/dev/null | sort -rn | head -1)"
    if [ -z "$NEWEST" ]; then
      # A registered directory with nothing in it yet — newly created, or everything in it
      # is hidden. Saying "last touched 1970-01-01" would be a lie dressed as data.
      printf -- '- %s — not under git, no files yet\n' "$NAME"
    else
      TS="${NEWEST%% *}"
      FILE="${NEWEST#* }"
      printf -- '- %s — not under git, last touched %s (%s)\n' \
        "$NAME" "$(date_ymd "$TS")" "$(basename "$FILE")"
    fi
  fi
done < <(registry)
