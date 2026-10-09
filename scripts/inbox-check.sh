#!/usr/bin/env bash
#
# Checks the Inbox board: which of Needs you / Working / Done a row lands in,
# when it archives, and what merges into what.
#
# Every rule here fails quietly. A row in the wrong column, or archived a minute
# early, is not a crash — it is an inbox that is missing the thing the user was
# waiting for, and the user finds out by not being told. That is the one failure
# a notification surface cannot have, so the rules are driven with constructed
# events rather than inspected on a screen.
#
# `InboxBoard.swift` and `AgentEvent.swift` are Foundation-only, so this needs
# no simulator and no host.
#
# Usage: scripts/inbox-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Shared/ISODate.swift" \
  "$ROOT/App/Features/Agents/AgentEvent.swift" \
  "$ROOT/App/Features/Agents/InboxBoard.swift" \
  "$ROOT/scripts/inbox/main.swift" 2>&1 | grep -v "^ *$" || true

[[ -x "$OUT/check" ]] || { echo "INBOX_BUILD_FAIL"; exit 1; }
"$OUT/check"
