#!/usr/bin/env bash
#
# Checks the syntax highlighter's lexing rules.
#
# Every rule here fails quietly and in the same way: the rest of the file is
# painted the wrong colour and nothing is reported. A `//` inside a string
# becomes a comment; an apostrophe in a comment swallows the document as an
# unterminated string; counting quotes instead of honouring escapes ends a
# string a character early or late. `SyntaxHighlighter.swift` is Foundation-only,
# so the whole file runs through a Swift interpreter with no simulator.
#
# Usage: scripts/syntax-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Features/Code/SyntaxHighlighter.swift" \
  "$ROOT/scripts/syntax/main.swift" 2>&1 | grep -v "^ *$" || true

[[ -x "$OUT/check" ]] || { echo "SYNTAX_BUILD_FAIL"; exit 1; }
"$OUT/check"
