#!/usr/bin/env bash
#
# Checks the side-by-side diff layout's pairing rule.
#
# The pairing fails silently both ways: pair too eagerly and an unrelated
# deletion and insertion read as one edit the agent never made; pair too rarely
# and every modification reads as a whole-line rewrite. Foundation-only, so this
# needs no simulator.
#
# Usage: scripts/sidebyside-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Features/Code/SideBySideDiff.swift" \
  "$ROOT/scripts/sidebyside/main.swift" 2>&1 | grep -v "^ *$" || true

[[ -x "$OUT/check" ]] || { echo "SIDEBYSIDE_BUILD_FAIL"; exit 1; }
"$OUT/check"
