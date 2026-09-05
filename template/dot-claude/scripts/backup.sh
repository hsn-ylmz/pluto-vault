#!/bin/bash
# Encrypted offsite bundle of the vault. Run by hand — `age -p` prompts for a passphrase.
#
# Encrypt before upload. This vault accumulates whatever you tell it, and consumer cloud
# storage is not where that belongs in cleartext.
#
# Target set at install time. Change it here, or export PLUTO_BACKUP_DIR to override.
set -eu

V="${PLUTO_HOME:-$HOME/pluto}"
OUT="{{BACKUP_DIR}}"
if [ -n "${PLUTO_BACKUP_DIR:-}" ]; then OUT="$PLUTO_BACKUP_DIR"; fi
LABEL="{{BACKUP_LABEL}}"
STAMP="$(date +%F)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v age >/dev/null || { echo "missing age — run: brew install age" >&2; exit 1; }

# macOS ships no timeout(1); coreutils provides gtimeout (brew install coreutils).
TIMEOUT_BIN="$(command -v gtimeout || command -v timeout || true)"
[ -n "$TIMEOUT_BIN" ] || { echo "missing gtimeout — run: brew install coreutils" >&2; exit 1; }

# A cloud mount can hang rather than fail. Probe it with a timeout and bail loudly instead
# of piping a git bundle into a wedged filesystem.
if ! "$TIMEOUT_BIN" 15 /bin/mkdir -p "$OUT" 2>/dev/null; then
  echo "BACKUP FAILED: $LABEL not responding at:" >&2
  echo "  $OUT" >&2
  echo "Open the $LABEL app, wait for it to finish mounting, and re-run." >&2
  exit 1
fi

cd "$V"
git bundle create "$TMP/pluto-$STAMP.bundle" --all
age -p -o "$TMP/pluto-$STAMP.bundle.age" "$TMP/pluto-$STAMP.bundle"

if ! "$TIMEOUT_BIN" 300 /bin/cp "$TMP/pluto-$STAMP.bundle.age" "$OUT/pluto-$STAMP.bundle.age"; then
  echo "BACKUP FAILED: could not write to $OUT (mount stalled mid-copy)" >&2
  exit 1
fi

echo "BACKUP OK: $OUT/pluto-$STAMP.bundle.age"
