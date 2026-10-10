#!/usr/bin/env bash
#
# Checks the Chat View header: which agent, model and session it names, and what
# its diff and preview controls offer.
#
# The derivations fail silently. A model shown wrongly still renders, a session
# id that is too long is not an error but a header squeezed to nothing, and a
# control summary that counts the wrong thing reads as working until someone
# taps it. They are driven here rather than inspected on a screen.
#
# `ChatHeader.swift` needs `AgentMessage` to exist, so `ChatTranscript.swift` is
# compiled in too. Both are Foundation-only.
#
# Usage: scripts/chat-header-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Shared/ISODate.swift" \
  "$ROOT/App/Features/Agents/ChatTranscript.swift" \
  "$ROOT/App/Features/Agents/ChatHeader.swift" \
  "$ROOT/scripts/chat-header/main.swift" 2>&1 | grep -v "^ *$" || true

[[ -x "$OUT/check" ]] || { echo "CHAT_HEADER_BUILD_FAIL"; exit 1; }
"$OUT/check"