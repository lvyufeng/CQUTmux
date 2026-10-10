#!/usr/bin/env bash
#
# Checks what the session picker's Recent tab offers.
#
# The sources look identical once drawn, and one distinction disappears when it
# is wrong: a host asked not to look and a host that looked and found nothing
# both produce an empty list. The rule is Foundation-only, so this needs no
# simulator.
#
# Usage: scripts/recent-picker-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Features/Hosts/Host.swift" \
  "$ROOT/App/Features/Terminal/LastSession.swift" \
  "$ROOT/App/Features/Agents/RecentDirectoryBoard.swift" \
  "$ROOT/App/Features/Terminal/RecentPicker.swift" \
  "$ROOT/scripts/recent-picker/main.swift" 2>&1 | grep -v "^ *$" || true

[[ -x "$OUT/check" ]] || { echo "RECENT_PICKER_BUILD_FAIL"; exit 1; }
"$OUT/check"
