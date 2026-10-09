#!/usr/bin/env bash
#
# Checks two halves of the tmux integration that both fail silently.
#
# 1. The prefix byte. Jump-To opens a window by *sending* the prefix key so
#    tmux interprets it rather than the pane; with the wrong prefix tmux
#    ignores the keystroke and the digit lands in the running program —
#    which, in a session with an agent at the prompt, means the agent is fed
#    a stray character. Nothing logs and nothing errors.
#
# 2. Which multiplexer a host actually runs. The window quick-access row
#    sends tmux keystrokes, so showing it for a zellij or herdr host types
#    control characters into the pane. The obvious implementation
#    (`contains("tmux")`) matches our *own default session name* in
#    `zellij attach -c cqutmux`, so this is checked against the real default
#    commands rather than invented ones.
#
# Both files are Foundation-only, so this needs no simulator.
#
# Usage: scripts/mux-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Features/Terminal/MuxSettings.swift" \
  "$ROOT/scripts/mux/main.swift"

# The detector needs `Host`, which is Foundation-only too.
swiftc -O -o "$OUT/detect" \
  "$ROOT/App/Features/Hosts/Host.swift" \
  "$ROOT/scripts/mux-detect/main.swift"

"$OUT/check" | tee "$OUT/results"
"$OUT/detect" | tee -a "$OUT/results"

if grep -q '^FAIL' "$OUT/results"; then
  exit 1
fi