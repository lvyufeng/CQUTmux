#!/usr/bin/env bash
#
# Checks the rc-injection half of the host-locale feature: the block written
# into ~/.zshenv and ~/.bashrc so non-interactive shells inherit LANG/LC_ALL.
#
# Both halves fail silently — a block appended twice sets the variable twice and
# the last one wins; a removal that leaves a stray line changes a shell's startup
# in a way nobody notices until something breaks — so the string functions are
# driven directly, and the command is run in a throwaway HOME that cannot edit
# the machine this is run on.
#
# Usage: scripts/locale-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> checking the block's rules"
node scripts/locale/main.mjs

echo "==> checking the command against a throwaway HOME"
FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT

fail() { echo "FAIL: $*"; exit 1; }

run() { HOME="$FAKE" node host/cqutmux-hook/index.mjs "$@"; }

# A file that already exists, with the user's own content in it.
printf 'export PATH=/usr/bin\n' > "$FAKE/.zshenv"

run locale en_US.UTF-8 > /dev/null || fail "locale en_US.UTF-8 exited non-zero"

grep -q 'export LANG=en_US.UTF-8' "$FAKE/.zshenv" || fail ".zshenv has no LANG line"
grep -q 'export LC_ALL=en_US.UTF-8' "$FAKE/.zshenv" || fail ".zshenv has no LC_ALL line"
grep -q 'export PATH=/usr/bin' "$FAKE/.zshenv" || fail ".zshenv lost the user's own line"
[ -f "$FAKE/.zshenv.cqutmux-backup" ] || fail "no backup was written before editing an existing file"

# Re-running must not stack a second block.
run locale en_US.UTF-8 > /dev/null
count=$(grep -c '# >>> cqutmux locale >>>' "$FAKE/.zshenv")
[ "$count" = "1" ] || fail "re-running left $count blocks, expected 1"

# A locale that is not a UTF-8 name is refused, and refused *before* touching
# the file: a partially-applied locale is worse than none.
before=$(cat "$FAKE/.zshenv")
if run locale 'en_US.UTF-8; rm -rf /' > /dev/null 2>&1; then
  fail "an unsafe locale was accepted"
fi
[ "$before" = "$(cat "$FAKE/.zshenv")" ] || fail "an unsafe locale still edited the file"

# Installing writes both shells' files, creating one that was absent: the whole
# point is that a login shell finds the block, and a host with no ~/.bashrc is
# one where bash reads nothing.
[ -f "$FAKE/.bashrc" ] || fail "install did not create the .bashrc it was asked to write"
grep -q 'export LANG' "$FAKE/.bashrc" || fail "the created .bashrc has no block"

# Unset removes the block from both, and leaves the user's content in the one
# that had any.
run locale unset > /dev/null
grep -q 'cqutmux locale' "$FAKE/.zshenv" && fail "unset left the block behind"
grep -q 'export PATH=/usr/bin' "$FAKE/.zshenv" || fail "unset removed the user's own line"
grep -q 'export LANG' "$FAKE/.zshenv" && fail "unset left an export behind"
grep -q 'export LANG' "$FAKE/.bashrc" && fail "unset left the block in .bashrc"

# Unset must not create a file: an uninstaller that invents a
# startup file has changed the user's shell in a way they did not ask for.
FRESH="$(mktemp -d)"
trap 'rm -rf "$FAKE" "$FRESH"' EXIT
HOME="$FRESH" node host/cqutmux-hook/index.mjs locale unset > /dev/null
[ -f "$FRESH/.bashrc" ] && fail "unset created a .bashrc that did not exist"
[ -f "$FRESH/.zshenv" ] && fail "unset created a .zshenv that did not exist"
HOME="$FRESH" node host/cqutmux-hook/index.mjs locale unset > /dev/null \
  || fail "unset on a host with no files exited non-zero"

echo "LOCALE_PASS"