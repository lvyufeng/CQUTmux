#!/usr/bin/env bash
#
# Checks the client-marker rules: what the toggle produces, and what it does
# when it is off.
#
# Worth having as a script because the failure mode is silent in both
# directions. A marker that is exported when the toggle is off changes what
# every existing install does on upgrade, and a marker that is *not* exported
# when it is on makes the setting a switch that does nothing — neither shows up
# as an error anywhere, and neither is visible in the app.
#
# The simulator checks (`MARKER_IS:1` / `MARKER_IS:unset` against a real sshd)
# prove the line reaches a real shell. This proves the line is the right one,
# on every host, without one.
#
# Usage: scripts/integrations-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# `IntegrationSettings.swift` alone: it imports Foundation and nothing else, so
# this needs no SwiftPM products and no simulator. The transport half lives in
# `IntegrationSettings+Transport.swift` for exactly this reason.
swiftc -O -o "$OUT/check" \
  "$ROOT/App/Features/Settings/IntegrationSettings.swift" \
  "$ROOT/scripts/integrations/main.swift"

"$OUT/check"