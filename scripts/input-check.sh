#!/usr/bin/env bash
#
# Checks the Input settings rules: Option-as-Meta, the bar's item order, the
# corner bindings, and the height heuristic that decides whether a hardware
# keyboard is attached.
#
# Worth a script because every one of these fails silently and looks like
# something else. A Meta translation that rewrites ordinary typing reads as a
# broken keyboard; a bar that hides itself reads as a layout bug; a corner that
# forgets its binding reads as a mis-tap. The simulator checks the screen and
# the bar; this checks the rules underneath, on every host, without one.
#
# `InputSettings.swift` imports SwiftUI for `@Observable` and nothing else from
# the app, so it compiles on its own.
#
# Usage: scripts/input-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# `ShortcutGrammar` is here because the custom D-pad corner action turns a
# typed shortcut into bytes through it — the store is what decides whether a
# corner is blank, so the grammar has to be on the compile line too.
swiftc -O -o "$OUT/check" \
  "$ROOT/App/Features/Terminal/ShortcutGrammar.swift" \
  "$ROOT/App/Features/Terminal/InputSettings.swift" \
  "$ROOT/scripts/input/main.swift"

"$OUT/check"