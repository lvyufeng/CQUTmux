#!/usr/bin/env bash
#
# Checks what a `cqutmux://` link parses to, without a simulator.
#
# A deep link is pasted into a terminal, a webhook or a chat message, so the
# parsing is the half a notification depends on: a link that parses to the
# wrong pane, or that silently drops the pane, is a tap that lands somewhere
# other than the notification was about — and nothing logs to say so.
#
# The parse is pure and `DeepLink.swift` is Foundation-only, so the asymmetry
# it carries is checked here rather than by opening the app: tmux and zellij
# address a window (and tmux a pane) by number and a typo must be caught before
# it is typed at the shell, while herdr addresses a tab by an opaque id where a
# number check would reject every valid link.
#
# `scripts/deeplink-test.sh` is the end-to-end companion, which drives the link
# through the app on a simulator but cannot see which value was parsed.
#
# Usage: scripts/deeplink-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Features/Terminal/DeepLink.swift" \
  "$ROOT/scripts/deeplink/main.swift"

"$OUT/check"