#!/usr/bin/env bash
#
# Checks the Chat View's approval bar: which pending approval belongs to the
# session on screen.
#
# Moshi puts the bar in the Chat View *in addition* to the Inbox — "Permission
# requests can appear in a floating approval bar with Approve and Deny" — and the
# buttons act on the live session. So the bar is a second surface for one action,
# and the one thing that must be right is which event it is about: show another
# session's approval and the user answers a decision they did not mean. That
# fails quietly on screen, so the selection rule is driven here.
#
# `ChatApproval.swift` and `AgentEvent.swift` are Foundation-only, so this needs
# no simulator and no host.
#
# Usage: scripts/chat-approval-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Shared/ISODate.swift" \
  "$ROOT/App/Features/Agents/AgentEvent.swift" \
  "$ROOT/App/Features/Agents/ChatApproval.swift" \
  "$ROOT/App/Features/Agents/ChatScroll.swift" \
  "$ROOT/App/Features/Agents/ChatWorking.swift" \
  "$ROOT/scripts/chat-approval/main.swift" 2>&1 | grep -v "^ *$" || true

[[ -x "$OUT/check" ]] || { echo "CHAT_APPROVAL_BUILD_FAIL"; exit 1; }
"$OUT/check"