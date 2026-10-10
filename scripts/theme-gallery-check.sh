#!/usr/bin/env bash
#
# Checks the bundled theme gallery against the real theme parser.
#
# The rule that matters is quiet: a gallery slug that disagrees with what
# `ThemeImport` derives from the theme's name turns a re-fetch into a duplicate.
# Both files are Foundation-only, so the whole catalogue is parsed here.
#
# Usage: scripts/theme-gallery-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Features/Settings/TerminalTheme.swift" \
  "$ROOT/App/Features/Settings/ThemeImport.swift" \
  "$ROOT/App/Features/Settings/ThemeGallery.swift" \
  "$ROOT/scripts/theme-gallery/main.swift" 2>&1 | grep -v "^ *$" || true

[[ -x "$OUT/check" ]] || { echo "THEME_GALLERY_BUILD_FAIL"; exit 1; }
"$OUT/check"
