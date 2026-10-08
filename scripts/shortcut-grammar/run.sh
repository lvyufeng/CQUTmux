#!/usr/bin/env bash
#
# Exercises ShortcutGrammar against the examples Moshi documents and the
# rejections it promises. The grammar is pure, so this needs no simulator:
# it compiles the file straight from the app target and runs the checks.
#
# Usage: scripts/shortcut-grammar/run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

cp "$ROOT/App/Features/Terminal/ShortcutGrammar.swift" "$OUT/"

swiftc -O -o "$OUT/check" \
  "$OUT/ShortcutGrammar.swift" \
  "$ROOT/scripts/shortcut-grammar/main.swift"

"$OUT/check" | tee "$OUT/results"

if grep -q '^FAIL' "$OUT/results"; then
  echo
  echo "grammar check FAILED" >&2
  exit 1
fi
echo
echo "grammar check passed"
