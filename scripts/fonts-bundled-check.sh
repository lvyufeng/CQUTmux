#!/usr/bin/env bash
#
# Checks the bundled terminal fonts: the files, their own name tables, the
# glyphs they carry, and that `UIAppFonts` lists them.
#
# Usage: scripts/fonts-bundled-check.sh
#
# What is asserted, and why each one is invisible on screen
# ---------------------------------------------------------
# A font that fails to load does not fail loudly. `UIFont(name:)` returns nil,
# the terminal falls back to the system monospaced face, and the user sees plain
# text and concludes the picker is decorative. Every failure mode looks the same
# from the screen:
#
# 1. A `.ttf` missing from `App/Fonts` but named by `EmbeddedFonts.files`.
# 2. A file present but not in `UIAppFonts`, so it is never registered.
# 3. A file in `UIAppFonts` that is not in the bundle, which registers nothing
#    and reports nothing.
# 4. A PostScript name in `TerminalFontFamily` that does not match the font's
#    own `name` table — a typo is enough, and iOS does not correct for it.
# 5. A subsetting step that dropped box-drawing or braille, so a TUI draws `?`.
#
# The assertions read the font binaries directly — the `name` and `cmap` tables
# are the source of truth — so this needs no font library and no simulator.
# The device half (that Core Text actually accepts them) is
# `CQUT_DEV_FONT_PROBE=1`, which writes `fonts.txt` into the app container.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

exec python3 -I scripts/fonts/font-check.py