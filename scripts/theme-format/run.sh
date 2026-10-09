#!/usr/bin/env bash
#
# Exercises the theme format: Moshi's documented v1 JSON, the fallbacks it
# promises, the rejections its rules imply, and a round trip through the
# `moshi-theme:` string.
#
# The format is what a user pastes in, so a case this gets wrong is a theme
# that imports as something else rather than failing loudly. The parser and the
# model are free of SwiftUI and SwiftTerm precisely so this needs no simulator.
#
# Usage: scripts/theme-format/run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Features/Settings/TerminalTheme.swift" \
  "$ROOT/App/Features/Settings/ThemeImport.swift" \
  "$ROOT/scripts/theme-format/main.swift"

"$OUT/check"