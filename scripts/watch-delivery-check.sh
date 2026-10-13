#!/usr/bin/env bash
#
# Checks that a decision taken on the watch can reach the phone at all.
#
# The watch has two ways to send one: `sendMessage` when the phone is
# reachable, and `transferUserInfo` when it is not — a queued transfer the
# system delivers on wake. `WatchBridge` implemented `didReceiveMessage` and
# nothing else, so a decision given while the phone was out of range was shown
# as taken on the wrist, queued, and dropped on arrival. Nothing on the watch
# can tell the difference; the wrist looked like it had worked.
#
# `WatchBridge.swift` cannot be compiled here — WatchConnectivity is not on
# macOS — so this reads the source. It is written as a pair rather than as two
# independent assertions: every send path the watch has must have a matching
# receive path on the phone, and both receives must funnel through one handler,
# because two delegates each decoding for themselves is how the queued path
# came to be missing and how the two would drift apart again.
#
# What is deliberately not asserted: that a queued transfer arrives, or how
# long it takes. That needs a paired watch and the phone's radio, neither of
# which exists here.
#
# Usage: scripts/watch-delivery-check.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WATCH="watch/ApprovalListView.swift"
BRIDGE="App/Features/Watch/WatchBridge.swift"

checks=0
fail=0
check() { # <condition> <label>
  checks=$((checks + 1))
  if [ "$1" = "1" ]; then
    printf 'PASS  %s\n' "$2"
  else
    printf 'FAIL  %s\n' "$2"
    fail=1
  fi
}

present() { grep -qF "$1" "$2" && echo 1 || echo 0; }
count() { grep -cF "$1" "$2" 2>/dev/null || true; }

echo "==> the watch's two send paths"

# The premise. If the watch ever stops having a queued path this check has
# nothing to say, and the pairing below would be vacuous rather than passing.
check "$(present 'transferUserInfo' "$WATCH")" \
  "an unreachable phone gets a queued transfer"
check "$(present 'sendMessage' "$WATCH")" \
  "a reachable one gets an immediate message"

echo "==> the phone receives both"

check "$(present 'didReceiveMessage' "$BRIDGE")" "the immediate path is handled"
check "$(present 'didReceiveUserInfo' "$BRIDGE")" "and so is the queued one"

echo "==> one handler, not two"

# Both delegates hand their dictionary to the same private function. Two
# decoding bodies would pass every check above and still be able to disagree.
check "$([ "$(count 'apply(message)' "$BRIDGE")" = "1" ] && echo 1 || echo 0)" \
  "the immediate delegate passes its payload on"
check "$([ "$(count 'apply(userInfo)' "$BRIDGE")" = "1" ] && echo 1 || echo 0)" \
  "and the queued delegate passes its own to the same place"
check "$([ "$(count 'onDecision?(' "$BRIDGE")" = "1" ] && echo 1 || echo 0)" \
  "exactly one place resolves an allow or deny"
check "$([ "$(count 'onAnswer?(' "$BRIDGE")" = "1" ] && echo 1 || echo 0)" \
  "and exactly one resolves a chosen option"

echo "==> both sides name the same key"

check "$(present 'WatchPayload.decisionKey' "$WATCH")" "the watch writes the decision under it"
check "$(present 'WatchPayload.decisionKey' "$BRIDGE")" "and the phone reads that one"

if [ "$fail" != "0" ]; then
  printf '\nWATCH_DELIVERY_FAIL  (%s checks)\n' "$checks"
  exit 1
fi
printf '\nWATCH_DELIVERY_PASS  (%s checks)\n' "$checks"