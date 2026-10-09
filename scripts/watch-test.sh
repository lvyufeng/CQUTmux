#!/usr/bin/env bash
#
# Exercises the Apple Watch approval path end to end: phone pushes pending
# approvals to the watch, the watch answers, the phone turns that answer into
# the same HookClient.resolve the Inbox uses, and the gateway records it.
#
# Usage: scripts/watch-test.sh [phone-name] [watch-name]
#
# Why this script pokes WCD's preferences
# ---------------------------------------
# On a real phone the system installs a paired watch's app for you, and WCD
# records that in `WCDStoredInstalledWatchApps`. `simctl` does not: it installs
# the watch app into the watch's own container and stops there, so the phone
# still believes no watch app exists and `updateApplicationContext` fails with
# `WCErrorCodeWatchAppNotInstalled` before a single byte leaves the device.
# Seeding that record stands in for the handshake the simulator skips. It is a
# harness fix, not an app fix — nothing in CQUTmux changes for it.
#
# Why CQUT_DEV_WATCH_APPROVE
# --------------------------
# There is no command-line way to tap the watch's Allow button, so the decision
# is injected by the watch app itself when that env var names an approval id. It
# calls the same `decide` the button calls, so everything after the tap —
# WatchLink.send, the phone's delegate, HookClient.resolve, the gateway — is the
# real path.
#
# (Touches *can* be injected — see host/cqutmux-hook/simtouch/ — but a tap on a
# button also depends on where the layout drew it, so the env hook stays for
# this: it fails for one reason, not two.)
set -euo pipefail

PHONE_NAME="${1:-iPhone 17}"
WATCH_NAME="${2:-Apple Watch Ultra 4 (49mm)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PATH="${ROOT}/scripts/et-ios/tools:${PATH}"
GATEWAY_PORT="${CQUT_DEV_GATEWAY_PORT:-24543}"
SEED_FILE="${SEED_FILE:-/tmp/cqut_sshd/seed.txt}"

udid_of() {
  xcrun simctl list devices available | grep -m1 "$1 (" | grep -oE '[0-9A-F-]{36}'
}

UDID="$(udid_of "$PHONE_NAME")"
WATCH="$(udid_of "$WATCH_NAME")"
[[ -n "$UDID" && -n "$WATCH" ]] || { echo "need both a phone and a watch simulator" >&2; exit 1; }

PHONE_PLIST="$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Library/Preferences/com.apple.wcd.plist"
APP="build/Build/Products/Debug-iphonesimulator/CQUTmux.app"
WATCH_APP="$APP/Watch/CQUTmuxWatch.app"
[[ -d "$WATCH_APP" ]] || { echo "no embedded watch app — build first (scripts/build.sh)" >&2; exit 1; }

echo "==> clearing the previous run"
xcrun simctl terminate "$UDID" app.cqutmux.ios 2>/dev/null || true
xcrun simctl terminate "$WATCH" app.cqutmux.ios.watchkitapp 2>/dev/null || true
xcrun simctl uninstall "$WATCH" app.cqutmux.ios.watchkitapp 2>/dev/null || true
xcrun simctl uninstall "$UDID" app.cqutmux.ios 2>/dev/null || true

echo "==> installing the phone app (this is what carries the watch app)"
xcrun simctl install "$UDID" "$APP"

echo "==> seeding the watch-install record the simulator never writes"
python3 - "$PHONE_PLIST" <<'PY'
import plistlib, sys
path = sys.argv[1]
try:
    with open(path, 'rb') as handle:
        prefs = plistlib.load(handle)
except FileNotFoundError:
    prefs = {}
prefs['WCDStoredInstalledWatchApps'] = ['app.cqutmux.ios.watchkitapp']
with open(path, 'wb') as handle:
    plistlib.dump(prefs, handle)
PY
# wcd holds preferences in memory, so it has to be restarted to see this.
xcrun simctl spawn "$UDID" launchctl kickstart -k system/com.apple.wcd 2>/dev/null || true
sleep 3

xcrun simctl install "$WATCH" "$WATCH_APP"

echo "==> posting an approval to the gateway"
EVENT="$(curl -fsS -X POST "http://127.0.0.1:${GATEWAY_PORT}/events" \
  -H 'Content-Type: application/json' \
  -d '{"source":"claude-code","kind":"approval","title":"Deploy to production?","body":"Claude Code wants to run scripts/deploy.sh."}')"
ID="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$EVENT")"
echo "    approval id = $ID"

SEED="$(cat "$SEED_FILE")"

echo "==> launching the watch, told to answer approval $ID"
SIMCTL_CHILD_CQUT_DEV_WATCH_APPROVE="$ID" \
  xcrun simctl launch "$WATCH" app.cqutmux.ios.watchkitapp >/dev/null
sleep 3

echo "==> launching the phone on the Inbox"
SIMCTL_CHILD_CQUT_DEV_HOST="${CQUT_DEV_HOST:-127.0.0.1}" \
SIMCTL_CHILD_CQUT_DEV_PORT="${CQUT_DEV_PORT:-2222}" \
SIMCTL_CHILD_CQUT_DEV_USER="${CQUT_DEV_USER:-$(whoami)}" \
SIMCTL_CHILD_CQUT_DEV_KEY_SEED="$SEED" \
SIMCTL_CHILD_CQUT_DEV_GATEWAY_PORT="$GATEWAY_PORT" \
SIMCTL_CHILD_CQUT_DEV_TAB=inbox \
  xcrun simctl launch "$UDID" app.cqutmux.ios >/dev/null
sleep 14

echo "==> watch session state as the phone sees it"
xcrun simctl spawn "$UDID" log show --last 40s --style compact \
  --predicate 'process == "CQUTmux"' 2>/dev/null \
  | grep -oE "reachable: [A-Z]+, paired: [A-Z]+, appInstalled: [A-Z]+" | sort -u

echo "==> did the watch's decision reach the gateway?"
xcrun simctl io "$WATCH" screenshot /tmp/cqutmux_watch.png >/dev/null 2>&1
xcrun simctl io "$UDID" screenshot /tmp/cqutmux_watch_phone.png >/dev/null 2>&1
EVENTS="$(curl -fsS "http://127.0.0.1:${GATEWAY_PORT}/events")"
python3 -c '
import json, sys
wanted = int(sys.argv[1])
events = json.loads(sys.argv[2])["events"]
target = next((e for e in events if e["id"] == wanted), None)
if target is None:
    print("FAIL: the approval never reached the gateway"); raise SystemExit(1)
if not target.get("resolvedAt"):
    print(f"FAIL: approval {wanted} is still pending — the watch decision did not arrive"); raise SystemExit(1)
decision, at = target["decision"], target["resolvedAt"]
print(f"PASS: approval {wanted} resolved by the watch — decision={decision} at {at}")
' "$ID" "$EVENTS"
echo "    screenshots: /tmp/cqutmux_watch.png /tmp/cqutmux_watch_phone.png"