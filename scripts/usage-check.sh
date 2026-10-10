#!/usr/bin/env bash
#
# Checks the per-agent usage windows: that Claude Code, Codex, OpenCode, Kimi
# Code and Grok Build do not all get the same fixed 5h/7d pair, and that the
# measurement against each window is right.
#
# Worth a script because the board's whole job is to answer "can I keep
# working?" and nothing on the screen can tell you a window is the wrong length.
# `usage.mjs` is plain node with no gateway behind it, so this needs no port.
#
# Usage: scripts/usage-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node --check "$ROOT/host/cqutmux-hook/usage.mjs"
node "$ROOT/scripts/usage/main.mjs"
