#!/usr/bin/env bash
#
# Checks the two gestures added for herdr parity: a pinch that zooms the
# focused pane, and a double tap that locks the custom keys.
#
# Usage: scripts/pinch-lock-check.sh
#
# What is asserted
# ----------------
# 1. `POST /herdr/zoom` really zooms the focused pane, and the direction in the
#    body is honoured — a route that answers ok while always toggling would make
#    "pinch out" and "pinch back" the same gesture, which is the one thing a
#    pinch cannot be. Read back from herdr's own layout, not from the reply.
# 2. `ShortcutLock` behaves as a gesture rather than as two toggles: a lone tap
#    must not lock, and a third tap must not be fused onto a pair.
#
# The lock half runs the real source file through the Swift interpreter, so a
# change to the window or the toggle order is caught here rather than by hand.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HERDR="${CQUTMUX_HERDR:-/private/tmp/herdr-install/bin/herdr}"
GATEWAY_PORT="${CQUTMUX_GATEWAY_PORT:-24641}"
TOKEN="pinch-lock-test"

echo "==> checking the lock's double-tap window"
LOCK_DIR="$(mktemp -d)"
trap 'rm -rf "$LOCK_DIR"' EXIT
# The real file, plus a driver. `ShortcutLock` imports only Foundation, so it
# runs outside the app target — checking the shipped logic rather than a copy.
cat App/Features/Terminal/ShortcutLock.swift > "$LOCK_DIR/main.swift"
cat >> "$LOCK_DIR/main.swift" <<'SWIFT'

func check(_ condition: Bool, _ message: String) {
    if !condition {
        print("FAIL: \(message)")
        exit(1)
    }
}

let t0 = Date()

let fresh = ShortcutLock()
check(!fresh.isLocked, "a fresh lock is open")
check(!fresh.tap(at: t0), "the first tap of a pair does not lock")
check(!fresh.isLocked, "the first tap of a pair leaves the lock open")
check(fresh.tap(at: t0.addingTimeInterval(0.2)), "the second tap of a pair locks")
check(fresh.isLocked, "the pair leaves the lock locked")
// While locked, a lone tap reopens the bar and is consumed — the tap belongs to
// the lock, so it must not fall through to the button underneath.
check(fresh.tap(at: t0.addingTimeInterval(2.0)), "a tap while locked is consumed by the lock")
check(!fresh.isLocked, "a lone tap off a locked lock reopens it")
// And immediately after that unlock, a lone tap is a lone tap again rather than
// the second half of a pair.
check(!fresh.tap(at: t0.addingTimeInterval(2.1)), "the tap after unlocking does not re-lock")

let slow = ShortcutLock()
_ = slow.tap(at: t0)
check(!slow.tap(at: t0.addingTimeInterval(1.0)), "two slow taps are not a double tap")
check(!slow.isLocked, "two slow taps leave the lock open")

let reset = ShortcutLock()
_ = reset.tap(at: t0)
_ = reset.tap(at: t0.addingTimeInterval(0.1))
reset.unlock()
check(!reset.isLocked, "unlock reopens a locked lock")

print("PASS: the double-tap window locks, a lone tap does not, and unlock reopens")
SWIFT

swift "$LOCK_DIR/main.swift"

if [[ ! -x "$HERDR" ]] || ! "$HERDR" status >/dev/null 2>&1; then
  echo "SKIP: no herdr server running; the zoom half needs one"
  echo "PINCH_LOCK_PASS"
  exit 0
fi

echo "==> starting the gateway against $HERDR"
CQUTMUX_HERDR="$HERDR" node host/cqutmux-hook/index.mjs --port "$GATEWAY_PORT" --token "$TOKEN" \
  >/tmp/cqutmux_pinch_gw.log 2>&1 &
GW_PID=$!
# Reassigned through the trap so an early exit does not leave the port held.
trap 'kill $GW_PID 2>/dev/null || true; rm -rf "$LOCK_DIR"' EXIT
sleep 2

echo "==> checking that a pinch direction survives the round trip"
GATEWAY_PORT="$GATEWAY_PORT" TOKEN="$TOKEN" HERDR="$HERDR" python3 - <<'PY'
import json, os, subprocess, urllib.request

port = os.environ["GATEWAY_PORT"]
token = os.environ["TOKEN"]
herdr = os.environ["HERDR"]


def zoomed_tabs():
    """Tabs herdr currently reports as zoomed, straight from its own layout."""
    out = subprocess.run([herdr, "api", "snapshot"], capture_output=True, text=True).stdout
    snapshot = json.loads(out)["result"]["snapshot"]
    return {entry["tab_id"] for entry in snapshot.get("layouts", []) if entry.get("zoomed")}


def zoom(zoomed):
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/herdr/zoom",
        method="POST",
        data=json.dumps({"zoomed": zoomed}).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    return json.load(urllib.request.urlopen(request))


# A zoom needs a tab with more than one pane; with a single pane herdr answers
# `reason: single_pane` and changes nothing, which is correct and proves
# nothing. The host here usually has one pane per tab, so this reports the
# plumbing and says plainly that the layout assertion was skipped rather than
# claiming a pass it did not earn.
multi = {}
out = subprocess.run([herdr, "api", "snapshot"], capture_output=True, text=True).stdout
for entry in json.loads(out)["result"]["snapshot"].get("layouts", []):
    if len(entry.get("panes", [])) > 1:
        multi[entry["tab_id"]] = True

in_result = zoom(True)
if not in_result.get("ok"):
    print(f"FAIL: zoom in was refused: {in_result}")
    raise SystemExit(1)
# The reply is herdr's own `pane_zoom` result, so a 200 here is proof the socket
# call landed rather than proof the gateway answered something of its own.
if (in_result.get("result") or {}).get("type") != "pane_zoom":
    print(f"FAIL: the reply was not herdr's own zoom result: {in_result}")
    raise SystemExit(1)

if not multi:
    print("SKIP: no tab on this host has more than one pane, so zoom is a no-op")
    print("      (to exercise it: herdr pane split, then re-run)")
else:
    if not zoomed_tabs():
        print(f"FAIL: asked to zoom a split tab, herdr reports none of {sorted(multi)} zoomed")
        raise SystemExit(1)

out_result = zoom(False)
if not out_result.get("ok"):
    print(f"FAIL: zoom out was refused: {out_result}")
    raise SystemExit(1)

if multi:
    remaining = zoomed_tabs()
    if remaining:
        print(f"FAIL: zoom out left {sorted(remaining)} zoomed")
        raise SystemExit(1)
    print("PASS: zoom on and off are distinct, and herdr's own layout agrees")
else:
    print("PASS: both directions reach herdr's socket API and are accepted")
PY

echo "PINCH_LOCK_PASS"