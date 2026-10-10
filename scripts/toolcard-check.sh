#!/usr/bin/env bash
#
# Checks the tool card's shape classifier: mini diffs, task lists and plans.
#
# Every rule here fails silently. A shape that is not recognised still renders,
# as raw JSON, so nothing reports an error and the card merely looks like the
# wrong thing. The rules are therefore driven with real tool payloads rather
# than inspected on a screen.
#
# `ToolShape.swift` is Foundation-only, so this needs no simulator.
#
# Usage: scripts/toolcard-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Features/Agents/ToolShape.swift" \
  "$ROOT/scripts/toolcard/main.swift" 2>&1 | grep -v "^ *$" || true

[[ -x "$OUT/check" ]] || { echo "TOOLCARD_BUILD_FAIL"; exit 1; }
"$OUT/check"