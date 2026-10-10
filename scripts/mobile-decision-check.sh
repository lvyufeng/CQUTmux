#!/usr/bin/env bash
#
# Checks the shared queue the Lock Screen's approval buttons write into.
#
# A tap that never arrives looks exactly like a tap the user did not make, and
# the approval simply sits in "Needs you" — which is also what a working denial
# looks like. `MobileDecision.swift` is Foundation-only, so the rules run here
# against a scratch defaults suite.
#
# Usage: scripts/mobile-decision-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Shared/MobileDecision.swift" \
  "$ROOT/scripts/mobile-decision/main.swift" 2>&1 | grep -v "^ *$" || true

[[ -x "$OUT/check" ]] || { echo "MOBILE_DECISION_BUILD_FAIL"; exit 1; }
"$OUT/check"

# The App Group name is the seam between the widget and the app: both write and
# read the queue through it, and if the two ever name a different container the
# tap is still recorded — on the widget's side — and simply never read back.
# Nothing throws; the approval just sits unanswered. So the name is required to
# be the same string in both sources *and* in both entitlements, which is four
# places a rename has to reach and one of which is easy to forget.
app_group() { grep -oE 'group\.[A-Za-z0-9._-]+' "$1" | head -1; }
fail=0
for f in App/Shared/MobileDecision.swift App/Shared/WatchPayload.swift \
         App/CQUTmux.entitlements Widgets/CQUTmuxWidgets.entitlements; do
  group="$(app_group "$ROOT/$f")"
  if [[ "$group" != "group.app.cqutmux.ios" ]]; then
    echo "FAIL  $f names '$group', not the shared group"
    fail=1
  else
    echo "PASS  $f uses the shared App Group"
  fi
done
[[ "$fail" == 0 ]] || exit 1
