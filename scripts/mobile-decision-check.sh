#!/usr/bin/env bash
#
# Checks the shared queue the Lock Screen's approval buttons write into.
#
# A tap that never arrives looks exactly like a tap the user did not make, and
# the approval simply sits in "Needs you" — which is also what a working denial
# looks like. `MobileDecision.swift` is Foundation-only, so the rules run here
# against a scratch defaults suite.
#
# Usage: scripts/mobile-decision-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Shared/MobileDecision.swift" \
  "$ROOT/scripts/mobile-decision/main.swift" 2>&1 | grep -v "^ *$" || true

[[ -x "$OUT/check" ]] || { echo "MOBILE_DECISION_BUILD_FAIL"; exit 1; }
"$OUT/check"
