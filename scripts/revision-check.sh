#!/usr/bin/env bash
#
# Checks that browsing a past commit navigates the way git's own paths do.
#
# A wrong path join or parent still resolves to a real directory, so the
# listing looks right while "up", the breadcrumb and the equality the view
# moves on all disagree — silent in both directions. `RevisionTree.swift` is
# Foundation-only, so the rules run here without a simulator.
#
# Usage: scripts/revision-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Features/Code/RevisionTree.swift" \
  "$ROOT/scripts/revision/main.swift" 2>&1 | grep -v "^ *$" || true

[[ -x "$OUT/check" ]] || { echo "REVISION_BUILD_FAIL"; exit 1; }
"$OUT/check"
