#!/usr/bin/env bash
#
# Drives the simulator preview end to end: app → SSH tunnel → gateway →
# IndigoHID helper → a booted simulator → back into the app's own frame.
#
# Usage: scripts/simulator-touch-app-check.sh
#
# Two phases, because the two halves fail differently
# ---------------------------------------------------
# Phase 1 sends a gesture through the view's own `send`, the method the touch
# surface's recognisers call. It checks the client and the host: that the
# request reaches the gateway, that the helper injects a touch, and that the
# target simulator's screen changes.
#
# Phase 2 puts a *real touch* on the phone's screen — via the same injector the
# app uses, on the phone's own simulator — so the coordinate mapping in
# TouchSurface is exercised. That mapping is the one part that fails silently
# and partially: using the view's bounds instead of the fitted frame letterboxes
# every point, so taps land in the middle and miss at the edges, which reads as
# flakiness rather than arithmetic. Phase 1 cannot see it, because it skips the
# recognisers entirely. Phase 2 needs a second booted simulator (the target must
# not be the device being touched) and is skipped without one.
#
# Needs a local sshd on 127.0.0.1:2222 with the seed in /tmp/cqut_sshd/seed.txt,
# the same fixture scripts/jumpto-check.sh uses, plus a booted iOS simulator.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATEWAY_PORT="${CQUTMUX_GATEWAY_PORT:-24655}"
TOKEN="simtouch-app-test"
SEED_FILE="${SEED_FILE:-/tmp/cqut_sshd/seed.txt}"
APP="build/Build/Products/Debug-iphonesimulator/CQUTmux.app"

fail=0
note() { printf 'SKIP  %s\n' "$1"; }

command -v xcrun >/dev/null || { echo "SKIP: no Xcode command line tools"; exit 0; }
[[ -f "$SEED_FILE" ]] || { echo "SKIP: no ssh fixture at $SEED_FILE"; exit 0; }
lsof -nP -iTCP:2222 -sTCP:LISTEN >/dev/null 2>&1 \
  || { echo "SKIP: no sshd listening on 127.0.0.1:2222"; exit 0; }
[[ -d "$APP" ]] || { echo "SKIP: no built app at $APP (run scripts/build.sh)"; exit 0; }

booted() {
  xcrun simctl list devices booted --json | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
out = []
for runtime, devices in (d.get("devices") or {}).items():
    if "iOS" not in runtime:
        continue
    for dev in devices:
        if dev.get("state") == "Booted":
            out.append(dev["udid"])
print("\n".join(out))'
}

PHONE_UDID="$(xcrun simctl list devices available | grep -m1 "${PHONE:-iPhone 18 Pro} (" | grep -oE '[0-9A-F-]{36}')"
[[ -n "$PHONE_UDID" ]] || { echo "SKIP: no device named ${PHONE:-iPhone 18 Pro}"; exit 0; }

# Any other booted device can be the target; the phone must not be it.
TARGET_UDID=""
while read -r udid; do
  [ -n "$udid" ] || continue
  [ "$udid" = "$PHONE_UDID" ] && continue
  TARGET_UDID="$udid"; break
done <<< "$(booted)"
[[ -n "$TARGET_UDID" ]] || { echo "SKIP: no second booted simulator to drive"; exit 0; }
echo "==> phone $PHONE_UDID drives target $TARGET_UDID"

HELPER="host/cqutmux-hook/simtouch/cqutmux-simtouch"
[[ -x "$HELPER" ]] || xcrun swiftc -O -o "$HELPER" host/cqutmux-hook/simtouch/inject.swift

echo "==> starting the gateway"
node host/cqutmux-hook/index.mjs --port "$GATEWAY_PORT" --token "$TOKEN" \
  >/tmp/cqutmux_simtouch_gw.log 2>&1 &
GW_PID=$!
trap 'kill $GW_PID 2>/dev/null || true' EXIT
sleep 2

# The target is put on Settings: it scrolls, so a gesture changes it in a way no
# clock tick can fake.
xcrun simctl terminate "$TARGET_UDID" com.apple.Preferences >/dev/null 2>&1 || true
xcrun simctl launch "$TARGET_UDID" com.apple.Preferences >/dev/null 2>&1 || true
sleep 4

# The app is reinstalled for every launch: a leftover install keeps its saved
# host and gateway port, and `simctl launch` on an already-running app silently
# ignores SIMCTL_CHILD_*.
launch_app() { # <extra env assignments...>
  xcrun simctl terminate "$PHONE_UDID" app.cqutmux.ios 2>/dev/null || true
  xcrun simctl uninstall "$PHONE_UDID" app.cqutmux.ios 2>/dev/null || true
  xcrun simctl install "$PHONE_UDID" "$APP"
  env "$@" xcrun simctl launch "$PHONE_UDID" app.cqutmux.ios >/dev/null
}

BASE_ENV=(
  SIMCTL_CHILD_CQUT_DEV_HOST=127.0.0.1
  SIMCTL_CHILD_CQUT_DEV_PORT=2222
  SIMCTL_CHILD_CQUT_DEV_USER="$(whoami)"
  SIMCTL_CHILD_CQUT_DEV_KEY_SEED="$(cat "$SEED_FILE")"
  SIMCTL_CHILD_CQUT_DEV_GATEWAY_PORT="$GATEWAY_PORT"
  SIMCTL_CHILD_CQUT_DEV_GATEWAY_TOKEN="$TOKEN"
  SIMCTL_CHILD_CQUT_DEV_NO_NOTIFS=1
  SIMCTL_CHILD_CQUT_DEV_TAB=code
  SIMCTL_CHILD_CQUT_DEV_SHEET=simulator
  SIMCTL_CHILD_CQUT_DEV_SIM_UDID="$TARGET_UDID"
)

# --- Phase 1: a gesture through the view's own send ---------------------------

echo "==> phase 1: a queued gesture from the app"
launch_app "${BASE_ENV[@]}" SIMCTL_CHILD_CQUT_DEV_SIM_TOUCH="0.5,0.8,0.5,0.3"
sleep 8
BEFORE="$(xcrun simctl io "$TARGET_UDID" screenshot /tmp/simtouch_p1_before.png >/dev/null 2>&1; md5 -q /tmp/simtouch_p1_before.png)"
sleep 12
AFTER="$(xcrun simctl io "$TARGET_UDID" screenshot /tmp/simtouch_p1_after.png >/dev/null 2>&1; md5 -q /tmp/simtouch_p1_after.png)"
if [ "$BEFORE" != "$AFTER" ]; then
  echo "PASS  a gesture sent from the app moved the simulator"
else
  echo "FAIL  the simulator is unchanged — the app's gesture did not land"
  fail=1
fi
if grep -q '"error"' /tmp/cqutmux_simtouch_gw.log; then
  echo "      gateway said: $(grep '"error"' /tmp/cqutmux_simtouch_gw.log | tail -1)"
fi

# --- Phase 2: a real touch on the preview's recognisers -----------------------

echo "==> phase 2: a touch on the preview's own surface"
xcrun simctl terminate "$TARGET_UDID" com.apple.Preferences >/dev/null 2>&1 || true
xcrun simctl launch "$TARGET_UDID" com.apple.Preferences >/dev/null 2>&1 || true
sleep 4
launch_app "${BASE_ENV[@]}" SIMCTL_CHILD_CQUT_DEV_SIM_CONTROL=1
sleep 9
xcrun simctl io "$PHONE_UDID" screenshot /tmp/cqutmux_simtouch_app.png >/dev/null 2>&1
BEFORE="$(xcrun simctl io "$TARGET_UDID" screenshot /tmp/simtouch_p2_before.png >/dev/null 2>&1; md5 -q /tmp/simtouch_p2_before.png)"
# A drag down the middle of the phone's screen, in *its* normalised space. The
# preview frame is fitted and centred, so this lands inside it.
printf '{"type":"swipe","x":0.5,"y":0.75,"x2":0.5,"y2":0.45,"ms":350}\n' | "$HELPER" "$PHONE_UDID"
sleep 4
AFTER="$(xcrun simctl io "$TARGET_UDID" screenshot /tmp/simtouch_p2_after.png >/dev/null 2>&1; md5 -q /tmp/simtouch_p2_after.png)"
if [ "$BEFORE" != "$AFTER" ]; then
  echo "PASS  a touch on the preview's own surface moved the simulator"
else
  echo "FAIL  the target is unchanged — the touch surface did not forward the drag"
  fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "SIMULATOR_TOUCH_APP_PASS"
else
  echo "SIMULATOR_TOUCH_APP_FAIL"
  exit 1
fi