#!/usr/bin/env bash
#
# Checks the tmux prefix setting: the byte each prefix sends, and that an
# unknown stored value falls back rather than breaking.
#
# Worth a script because the failure is silent in the worst way. Jump-To opens
# a window by *sending* the prefix key so tmux interprets it rather than the
# pane; with the wrong prefix tmux ignores the keystroke and the digit lands in
# the running program — which, in a session with an agent at the prompt, means
# the agent is fed a stray character. Nothing logs and nothing errors.
#
# `MuxSettings.swift` imports only Foundation and Observation, so this needs no
# simulator. The end-to-end half (Jump-To against a real tmux with a non-default
# prefix) is `scripts/watch-test.sh`'s territory; this is the arithmetic.
#
# Usage: scripts/mux-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Features/Terminal/MuxSettings.swift" \
  "$ROOT/scripts/mux/main.swift"

"$OUT/check"