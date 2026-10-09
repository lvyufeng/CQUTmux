#!/usr/bin/env bash
#
# Checks the OpenSSH private-key reader against keys ssh-keygen makes.
#
# The fixtures are generated here rather than committed: a checked-in private
# key is a private key in the repository, even a throwaway one, and a reviewer
# should not have to work out which one it was. ssh-keygen is present wherever
# this project is built.
#
# Usage: scripts/key-import-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

command -v ssh-keygen >/dev/null || { echo "SKIP: no ssh-keygen to make fixtures with"; exit 0; }

# An unencrypted ed25519 key, a passphrase-protected one, and an RSA key — the
# three things the reader has to tell apart.
ssh-keygen -q -t ed25519 -N "" -C "cqutmux-check" -f "$OUT/id_ed25519"
ssh-keygen -q -t ed25519 -N "a passphrase" -C "cqutmux-check" -f "$OUT/id_ed25519_encrypted"
ssh-keygen -q -t rsa -b 2048 -N "" -C "cqutmux-check" -f "$OUT/id_rsa"

# Through the package, because the reader imports `Crypto` and is inside the
# module — compiling it standalone would need a second copy of the import
# surface that could drift from the one the app builds against.
echo "==> building KeyImportChecks"
swift build --package-path "$ROOT/Packages/CQUTTransport" --product KeyImportChecks >/dev/null

BIN="$(swift build --package-path "$ROOT/Packages/CQUTTransport" --product KeyImportChecks --show-bin-path)/KeyImportChecks"
[[ -x "$BIN" ]] || { echo "KEY_IMPORT_BUILD_FAIL" >&2; exit 1; }

KEY_IMPORT_TMPDIR="$OUT" "$BIN"