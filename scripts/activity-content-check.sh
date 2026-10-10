#!/usr/bin/env bash
#
# What the Live Activity's Lock Screen buttons answer.
#
# A tap that carries the wrong id is invisible: the approval it was meant to
# answer stays in "Needs you", which is also what a tap the user never made
# looks like. `AgentActivityPreview` decides which id travels with which title,
# and it is Foundation-only, so the rule runs here without ActivityKit.
#
# Usage: scripts/activity-content-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Features/Agents/AgentEvent.swift" \
  "$ROOT/App/Shared/ActivityPhase.swift" \
  "$ROOT/App/Shared/ISODate.swift" \
  "$ROOT/App/Features/Agents/AgentActivityPreview.swift" \
  "$ROOT/scripts/activity-content/main.swift" 2>&1 | grep -v "^ *$" || true

[[ -x "$OUT/check" ]] || { echo "ACTIVITY_CONTENT_BUILD_FAIL"; exit 1; }
"$OUT/check"
