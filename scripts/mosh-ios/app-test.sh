#!/usr/bin/env bash
#
# Exercises the mosh path through the *app*, not through the driver harness:
# SSH to the host, resolve mosh-server, start it, and drive the terminal over
# mosh's UDP session. The C-level test in test.sh proves the client libraries
# work; this proves the wiring in the app does.
#
# Needs a local sshd reachable from the simulator (see the harness in
# /tmp/cqut_sshd, or any host) with mosh-server installed.
#
# Usage: scripts/mosh-ios/app-test.sh [device-name]
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

echo "==> launching against ${CQUT_DEV_HOST:-127.0.0.1} as a mosh host"
xcrun simctl terminate "$UDID" app.cqutmux.ios 2>/dev/null || true
SIMCTL_CHILD_CQUT_DEV_HOST="${CQUT_DEV_HOST:-127.0.0.1}" \
SIMCTL_CHILD_CQUT_DEV_PORT="${CQUT_DEV_PORT:-2222}" \
SIMCTL_CHILD_CQUT_DEV_USER="${CQUT_DEV_USER:-$(whoami)}" \
SIMCTL_CHILD_CQUT_DEV_KEY_SEED="$SEED" \
SIMCTL_CHILD_CQUT_DEV_TRANSPORT="${CQUT_DEV_TRANSPORT:-mosh}" \
SIMCTL_CHILD_CQUT_DEV_TYPE="${CQUT_DEV_TYPE:-echo TYPED_INPUT_OK}" \
  xcrun simctl launch "$UDID" app.cqutmux.ios

echo "==> waiting for the session to come up and the keystrokes to round-trip"
sleep 16

echo "==> capturing"
SHOT="${SHOT:-/tmp/cqutmux_mosh_app.png}"
xcrun simctl io "$UDID" screenshot "$SHOT"
echo "    $SHOT"

echo "==> did mosh-server actually run?"
pgrep -fl "mosh-server new" || echo "    no mosh-server process"