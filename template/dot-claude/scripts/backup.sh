#!/bin/bash
# Encrypted offsite bundle of the vault.
#
# Encrypts to an age *public key*, so it needs no passphrase and no terminal. That is the
# whole point: `age -p` reads from /dev/tty, which made this impossible to run unattended,
# so it ran once. A recipient key lets launchd run it nightly.
#
# The matching private key is the only way back in:
#
#     ~/.config/age/pluto-backup.txt      mode 600, outside the vault, never in a git repo
#
# Keep a copy in a password manager. A bundle whose key is lost is not a backup, it is 180KB of
# noise — there is no recovery path and no one to ask.
#
# Restore:
#     age -d -i ~/.config/age/pluto-backup.txt -o pluto.bundle pluto-<date>.bundle.age
#     git clone pluto.bundle pluto-restored
set -eu

V="${PLUTO_HOME:-$HOME/pluto}"
OUT="${PLUTO_BACKUP_OUT:-$HOME/pluto-backups}"
RECIPIENT="${PLUTO_AGE_RECIPIENT:-age1lfsats46m6gh3w4m4qc4zav3lcejv9ust489fkhpg53cj7rv6v7q9ysvem}"
IDENTITY="${PLUTO_AGE_IDENTITY:-$HOME/.config/age/pluto-backup.txt}"
STAMP="$(date +%F)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# macOS ships no timeout(1); coreutils provides gtimeout (brew install coreutils).
TIMEOUT_BIN="$(command -v gtimeout || true)"
[ -n "$TIMEOUT_BIN" ] || { echo "missing gtimeout - run: brew install coreutils" >&2; exit 1; }
run_with_timeout() { "$TIMEOUT_BIN" "$@"; }

# The sync-folder mount can hang rather than fail. Probe it with a timeout and bail loudly
# instead of piping a git bundle into a wedged filesystem.
if ! run_with_timeout 15 /bin/mkdir -p "$OUT" 2>/dev/null; then
  echo "BACKUP FAILED: the cloud sync folder not responding at:" >&2
  echo "  $OUT" >&2
  echo "Open the the cloud sync folder app, wait for it to finish mounting, and re-run." >&2
  exit 1
fi

cd "$V"
git bundle create "$TMP/pluto-$STAMP.bundle" --all
age -r "$RECIPIENT" -o "$TMP/pluto-$STAMP.bundle.age" "$TMP/pluto-$STAMP.bundle"

# Verify before shipping, not after. An encrypted file is opaque: without this the script
# would happily copy a truncated or unreadable bundle to the sync folder and print BACKUP OK, and
# the failure would surface on the day it is needed. Decrypt the artifact that is about to
# be sent and check git can read it.
if [ -r "$IDENTITY" ]; then
  if ! age -d -i "$IDENTITY" -o "$TMP/verify.bundle" "$TMP/pluto-$STAMP.bundle.age" 2>"$TMP/age.err"; then
    echo "BACKUP FAILED: cannot decrypt what was just encrypted: $(cat "$TMP/age.err")" >&2
    echo "  The recipient in RECIPIENT does not match the key in $IDENTITY." >&2
    exit 1
  fi
  if ! git bundle verify "$TMP/verify.bundle" >"$TMP/verify.out" 2>&1; then
    echo "BACKUP FAILED: decrypted bundle is not a valid git bundle:" >&2
    sed 's/^/    /' "$TMP/verify.out" >&2
    exit 1
  fi
else
  # Not fatal — encryption only needs the public key, and the identity may deliberately
  # live only in a password manager. But say so, because an unverified backup is a promise.
  echo "WARNING: $IDENTITY not readable — wrote the bundle without verifying it." >&2
  echo "         Restore has not been proven. Decrypt one by hand to confirm." >&2
fi

if ! run_with_timeout 300 /bin/cp "$TMP/pluto-$STAMP.bundle.age" "$OUT/pluto-$STAMP.bundle.age"; then
  echo "BACKUP FAILED: could not write to $OUT (mount stalled mid-copy)" >&2
  exit 1
fi

echo "BACKUP OK: $OUT/pluto-$STAMP.bundle.age"
