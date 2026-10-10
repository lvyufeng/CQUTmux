#!/usr/bin/env bash
#
# Checks that the terminal resumes the last session: whether to resume, and
# whether the record survives.
#
# Both halves fail silently. Resuming when the screen is already on that session
# types an attach command into a live pane; resuming over a deep link fights the
# link; a record that does not survive the app closing simply never resumes, and
# nothing says why. `LastSession.swift` is Foundation-only, so the decision and
# the store are driven here without a simulator.
#
# Usage: scripts/last-session-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Features/Hosts/Host.swift" \
  "$ROOT/App/Features/Terminal/LastSession.swift" \
  "$ROOT/scripts/last-session/main.swift" 2>&1 | grep -v "^ *$" || true

[[ -x "$OUT/check" ]] || { echo "LAST_SESSION_BUILD_FAIL"; exit 1; }
"$OUT/check"