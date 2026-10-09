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
cp "$ROOT/App/Features/Terminal/GestureBinding.swift" "$OUT/"

swiftc -O -o "$OUT/check" \
  "$OUT/ShortcutGrammar.swift" \
  "$ROOT/scripts/shortcut-grammar/main.swift"

# The gesture store needs `@Observable`, which pulls in the macro plugin; it
# gets its own binary so the grammar check stays a plain single-file compile.
swiftc -O -o "$OUT/gestures" \
  "$OUT/ShortcutGrammar.swift" \
  "$OUT/GestureBinding.swift" \
  "$ROOT/scripts/shortcut-grammar/gestures.swift"

"$OUT/check" | tee "$OUT/results"
"$OUT/gestures" | tee -a "$OUT/results"

if grep -q '^FAIL' "$OUT/results"; then
  echo
  echo "grammar check FAILED" >&2
  exit 1
fi
echo
echo "grammar check passed"
