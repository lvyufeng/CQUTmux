#!/usr/bin/env bash
#
# Checks the chat's Markdown splitter: prose, fenced code and inline images.
#
# Every rule here fails silently. A fence that is not recognised still renders —
# as one blob of prose with the backticks showing — so the message merely looks
# like the agent wrote rubbish, and nothing reports an error. The rules are
# therefore driven with real messages rather than inspected on a screen.
#
# `ChatMarkdown.swift` is Foundation-only, so this needs no simulator.
#
# Usage: scripts/chat-markdown-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Features/Agents/ChatMarkdown.swift" \
  "$ROOT/scripts/chat-markdown/main.swift" 2>&1 | grep -v "^ *$" || true

[[ -x "$OUT/check" ]] || { echo "CHAT_MARKDOWN_BUILD_FAIL"; exit 1; }
"$OUT/check"