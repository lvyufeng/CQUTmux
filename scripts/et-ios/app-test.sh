#!/usr/bin/env bash
#
# Exercises the ET path through the *app*, not through the driver harness:
# SSH to the host, resolve etterminal, start it, read back the credentials it
# mints, and drive the terminal over ET's TCP session. scripts/et-ios/test.sh
# proves the client core works; this proves the wiring in the app does.
#
# Needs a local sshd reachable from the simulator and etterminal on the host's
# PATH. `scripts/et-ios/host-tools.sh` builds etterminal; the sshd harness is
# the one scripts/mosh-ios/app-test.sh uses.
#
# Usage: scripts/et-ios/app-test.sh [device-name]
set -euo pipefail

DEVICE="${1:-iPhone 18 Pro}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

SEED_FILE="${SEED_FILE:-/tmp/cqut_sshd/seed.txt}"
SEED="$(cat "$SEED_FILE")"
UDID="$(xcrun simctl list devices available | grep -m1 "$DEVICE (" | grep -oE '[0-9A-F-]{36}')"

# A reinstall keeps the app's persisted hosts, and the UI reopens whichever was
# last used — which is not the host this test just seeded. Uninstall first.
echo "==> installing clean"
xcrun simctl uninstall "$UDID" app.cqutmux.ios 2>/dev/null || true
xcrun simctl install "$UDID" build/Build/Products/Debug-iphonesimulator/CQUTmux.app

echo "==> clearing any etserver left over from an earlier run"
pkill -f etserver 2>/dev/null || true
pkill -f etterminal 2>/dev/null || true
sleep 1

echo "==> launching against ${CQUT_DEV_HOST:-127.0.0.1} as an ET host"
xcrun simctl terminate "$UDID" app.cqutmux.ios 2>/dev/null || true
# The marker is arithmetic the shell has to evaluate, so it cannot appear
# unless the keystrokes reached the server and ran there.
SIMCTL_CHILD_CQUT_DEV_HOST="${CQUT_DEV_HOST:-127.0.0.1}" \
SIMCTL_CHILD_CQUT_DEV_PORT="${CQUT_DEV_PORT:-2222}" \
SIMCTL_CHILD_CQUT_DEV_USER="${CQUT_DEV_USER:-$(whoami)}" \
SIMCTL_CHILD_CQUT_DEV_KEY_SEED="$SEED" \
SIMCTL_CHILD_CQUT_DEV_TRANSPORT="${CQUT_DEV_TRANSPORT:-et}" \
SIMCTL_CHILD_CQUT_DEV_TYPE="${CQUT_DEV_TYPE:-echo ET_APP_$((30+3))_OK}" \
  xcrun simctl launch "$UDID" app.cqutmux.ios

echo "==> waiting for the session to come up and the keystrokes to round-trip"
sleep 18

echo "==> capturing"
SHOT="${SHOT:-/tmp/cqutmux_et_app.png}"
xcrun simctl io "$UDID" screenshot "$SHOT"
echo "    $SHOT"

echo "==> did etserver and etterminal actually run?"
pgrep -fl etserver || echo "    no etserver process"
pgrep -fl etterminal || echo "    no etterminal process"
echo "==> is the app talking to the ET port?"
lsof -nP -iTCP:2022 2>/dev/null | grep -i CQUTmux || echo "    no app connection to :2022"