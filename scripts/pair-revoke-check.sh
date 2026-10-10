#!/usr/bin/env bash
#
# Checks `cqutmux unpair` against a real `authorized_keys`.
#
# Usage: scripts/pair-revoke-check.sh
#
# What is asserted
# ----------------
# Pairing is one line in `~/.ssh/authorized_keys`; unpairing has to remove
# exactly that line and leave the rest of the file alone. The file is shared
# with every other tool on the machine, so the failure that matters is not
# "the key is still there" — it is "the key is gone and so is something else".
#
# Run against a throwaway HOME, so nothing here touches the real key store.
#
#   1. The cqutmux line is removed and the user's own key survives byte for byte.
#   2. A re-run changes nothing (unpairing an unpaired host is not an edit).
#   3. `--delete-key` removes the key pair; without it the pair is kept.
#   4. A host that was never paired says so and exits without an error.
#   5. A line matching on the key blob is removed even when its comment was
#      changed — the comment is ours but a renamed host edits it, and the blob
#      is what actually grants access.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/host/cqutmux-hook/index.mjs"
PASS=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; exit 1; }

# A throwaway host: a HOME with a .ssh, a cqutmux key pair, and an
# authorized_keys holding both our key and the user's own.
boothost() {
  local home="$1"
  mkdir -p "$home/.ssh"
  printf 'ssh-ed25519 AAAAC3NzaCQUTMUX our-key cqutmux@somehost\nssh-ed25519 AAAAC3NzaMINE user-key me@laptop\n' \
    > "$home/.ssh/authorized_keys"
  printf 'ssh-ed25519 AAAAC3NzaCQUTMUX our-key cqutmux@somehost\n' > "$home/.ssh/cqutmux_ed25519.pub"
  printf 'PRIVATE\n' > "$home/.ssh/cqutmux_ed25519"
}

# MARK: - the ordinary case

H1="$TMP/h1"; boothost "$H1"
HOME="$H1" node "$CLI" unpair > /dev/null 2>&1 || fail "unpair exited non-zero"

grep -q "CQUTMUX" "$H1/.ssh/authorized_keys" && fail "the cqutmux key is still authorised"
ok "the paired key is revoked"

grep -q "AAAAC3NzaMINE user-key me@laptop" "$H1/.ssh/authorized_keys" \
  || fail "the user's own key was removed too"
ok "the user's own key survives"

# And it survives *unchanged* — not merely present. A rewrite that reformats it
# is an edit to someone else's file that they did not ask for.
[ "$(cat "$H1/.ssh/authorized_keys")" = "ssh-ed25519 AAAAC3NzaMINE user-key me@laptop" ] \
  || fail "the user's line was reformatted: $(cat "$H1/.ssh/authorized_keys")"
ok "the surviving line is byte for byte what it was"

test -f "$H1/.ssh/cqutmux_ed25519" || fail "the key pair was deleted without --delete-key"
ok "the key pair is kept by default"

# MARK: - idempotence

H2="$TMP/h2"; boothost "$H2"
HOME="$H2" node "$CLI" unpair > /dev/null 2>&1
BEFORE="$(md5 -q "$H2/.ssh/authorized_keys" 2>/dev/null || md5sum "$H2/.ssh/authorized_keys" | cut -d' ' -f1)"
HOME="$H2" node "$CLI" unpair > /dev/null 2>&1 || fail "a second unpair exited non-zero"
AFTER="$(md5 -q "$H2/.ssh/authorized_keys" 2>/dev/null || md5sum "$H2/.ssh/authorized_keys" | cut -d' ' -f1)"
[ "$BEFORE" = "$AFTER" ] || fail "a second unpair changed the file"
ok "unpairing an unpaired host is not an edit"

# MARK: - --delete-key

H3="$TMP/h3"; boothost "$H3"
HOME="$H3" node "$CLI" unpair --delete-key > /dev/null 2>&1 || fail "unpair --delete-key failed"
test -f "$H3/.ssh/cqutmux_ed25519" && fail "--delete-key left the private key"
test -f "$H3/.ssh/cqutmux_ed25519.pub" && fail "--delete-key left the public key"
ok "--delete-key removes the pair"

# MARK: - never paired

H4="$TMP/h4"; mkdir -p "$H4/.ssh"
HOME="$H4" node "$CLI" unpair > /dev/null 2>&1 \
  || fail "unpair on an unpaired host exited non-zero"
ok "a host with no authorized_keys is not an error"

# MARK: - matched by blob, not by comment

H5="$TMP/h5"; boothost "$H5"
# The same key, but the comment renamed — as a host rename would leave it.
printf 'ssh-ed25519 AAAAC3NzaCQUTMUX our-key cqutmux@RENAMED\nssh-ed25519 AAAAC3NzaMINE user-key me@laptop\n' \
  > "$H5/.ssh/authorized_keys"
HOME="$H5" node "$CLI" unpair > /dev/null 2>&1 || fail "unpair failed on a renamed comment"
grep -q "CQUTMUX" "$H5/.ssh/authorized_keys" \
  && fail "a renamed comment left the key authorised"
ok "the key is matched by its blob, so a renamed comment still revokes"

printf '\nPAIR_REVOKE_PASS  (%d checks)\n' "$PASS"