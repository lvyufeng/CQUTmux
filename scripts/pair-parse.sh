#!/usr/bin/env bash
#
# Runs a link through the app's own `Pairing` code, from the shell.
#
# The host writes the pairing link in JavaScript and the app reads it in Swift,
# and the failure this guards against is the two describing the format
# differently: the host prints something that looks like a link and the app
# refuses it, or accepts it and binds to the wrong host. A check that reads the
# host's output with a second reader written in the check cannot see that. This
# compiles the file the app actually ships and uses it.
#
# Built once into a cache and reused while the sources are unchanged, because
# `scripts/cli-check.sh` calls it several times and a Swift compile each time
# would make the suite slow enough to be skipped.
#
# Usage:
#   scripts/pair-parse.sh build            payload JSON on stdin -> link
#   scripts/pair-parse.sh link <url>       link -> the fields, as JSON
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${TMPDIR:-/tmp}/cqutmux-pair-parse"

if [[ ! -x "$BIN" || "$ROOT/App/Shared/Pairing.swift" -nt "$BIN" || "$ROOT/scripts/pair-parse/main.swift" -nt "$BIN" ]]; then
  swiftc -o "$BIN" \
    "$ROOT/App/Shared/Pairing.swift" \
    "$ROOT/scripts/pair-parse/main.swift" 2>&1 | grep -vE "warning:" || true
fi

[[ -x "$BIN" ]] || { echo "PAIR_PARSE_BUILD_FAIL" >&2; exit 1; }
"$BIN" "$@"