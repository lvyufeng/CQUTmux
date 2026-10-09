#!/usr/bin/env bash
#
# Checks the pairing link a host prints and a phone scans.
#
# One machine writes it, another reads it, and there is no error channel in
# between: a field that does not survive the round trip is not a rejected link,
# it is a connection that authenticates as nobody or a gateway token that is
# silently empty. And the private key travels through a QR code, so where it
# sits in the URL decides whether it leaks into logs.
#
# `Pairing.swift` is Foundation-only, so this needs no simulator.
#
# Usage: scripts/pair-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -o "$OUT/check" \
  "$ROOT/App/Shared/Pairing.swift" \
  "$ROOT/scripts/pair/main.swift" 2>&1 | grep -vE "warning:" || true

[[ -x "$OUT/check" ]] || { echo "PAIR_BUILD_FAIL"; exit 1; }
"$OUT/check"
