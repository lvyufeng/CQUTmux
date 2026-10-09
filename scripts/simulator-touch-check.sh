#!/usr/bin/env bash
#
# Checks live simulator touch control: the host helper that injects touches, the
# gateway route that fronts it, and — on a host with a booted simulator — that a
# gesture actually changes the device's screen.
#
# Usage: scripts/simulator-touch-check.sh
#
# Why this is not a unit test
# ---------------------------
# The failure this guards is the one that looks like success. The helper prints
# `{"ok":true}` as soon as it has handed the Indigo message to CoreSimulator —
# but the message crosses XPC, and a process that exits before the run loop
# turns delivers nothing. That exact bug was in the first version of this
# helper: every gesture reported ok and no gesture did anything. No check that
# stops at the helper's reply can see it. Only comparing screenshots before and
# after a gesture can, which is why the interesting section here needs a booted
# simulator and takes two frames.
#
# The parts that do not need a simulator are still checked, so a host without
# Xcode gets a useful answer rather than nothing.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HOST_DIR="host/cqutmux-hook"
HELPER="$HOST_DIR/simtouch/cqutmux-simtouch"
SOURCE="$HOST_DIR/simtouch/inject.swift"
MODULE="$HOST_DIR/simtouch.mjs"

pass=0
fail=0
skip=0
check() { # <condition> <label>
  if [ "$1" = "1" ]; then
    printf 'PASS  %s\n' "$2"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s\n' "$2"
    fail=$((fail + 1))
  fi
}
note() { printf 'SKIP  %s\n' "$1"; skip=$((skip + 1)); }

# --- The pieces are where the gateway expects them ---------------------------

echo "==> checking the helper source and the gateway route"

check "$([ -f "$SOURCE" ] && echo 1 || echo 0)" "the helper source is present ($SOURCE)"
check "$([ -f "$MODULE" ] && echo 1 || echo 0)" "the gateway module is present ($MODULE)"

# The route has to be wired, not merely implemented: an endpoint nothing calls
# inside index.mjs is the same as no endpoint.
check "$(grep -q "'/simulator/touch'" "$HOST_DIR/index.mjs" && echo 1 || echo 0)" \
  "the gateway routes POST /simulator/touch"
check "$(grep -q 'sendGesture' "$HOST_DIR/index.mjs" && echo 1 || echo 0)" \
  "the route calls sendGesture"
check "$(grep -q 'stopAllSessions' "$HOST_DIR/index.mjs" && echo 1 || echo 0)" \
  "helpers are stopped when the gateway exits"

# Syntax, so a typo in either file fails here rather than at the first gesture.
check "$(node --check "$HOST_DIR/index.mjs" >/dev/null 2>&1 && echo 1 || echo 0)" \
  "the gateway parses"
check "$(node --check "$MODULE" >/dev/null 2>&1 && echo 1 || echo 0)" \
  "the touch module parses"

# --- The app side is wired to the same route ---------------------------------

echo "==> checking the app's half"

check "$(grep -q 'simulatorTouch' App/Features/Agents/HookClient.swift && echo 1 || echo 0)" \
  "the client has a simulatorTouch call"
check "$(grep -q '"/simulator/touch"' App/Features/Agents/HookClient.swift && echo 1 || echo 0)" \
  "the client posts to /simulator/touch"
check "$(grep -q 'struct TouchSurface' App/Features/Preview/SimulatorPreviewView.swift && echo 1 || echo 0)" \
  "the preview has a touch surface"
# Control must default to off: a preview someone opened to watch must not turn
# a stray tap into input on a device they are not looking at.
check "$(grep -q 'private var control: Bool = false\|@State private var control = false' \
  App/Features/Preview/SimulatorPreviewView.swift && echo 1 || echo 0)" \
  "touch control is off by default"

# --- The live half, when a simulator is available ----------------------------

echo "==> checking a real touch against a booted simulator"

SIMCTL="$(xcrun -f simctl 2>/dev/null || true)"
BOOTED=""
if [ -n "$SIMCTL" ]; then
  BOOTED="$("$SIMCTL" list devices booted --json 2>/dev/null \
    | python3 -I -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for runtime, devices in (d.get("devices") or {}).items():
    if "iOS" not in runtime:
        continue
    for dev in devices:
        if dev.get("state") == "Booted":
            print(dev["udid"]); break
    else:
        continue
    break' 2>/dev/null || true)"
fi

if [ -z "$BOOTED" ]; then
  note "no booted iOS simulator — the live gesture check did not run"
else
  echo "    using simulator $BOOTED"

  # Build the helper the same way the gateway would, so this checks the shipped
  # source rather than a binary that happened to be left behind.
  if [ -f "$HELPER" ]; then rm -f "$HELPER"; fi
  if ! xcrun swiftc -O -o "$HELPER" "$SOURCE" 2>/tmp/simtouch-build.log; then
    check 0 "the helper builds from source ($(head -1 /tmp/simtouch-build.log))"
  else
    check 1 "the helper builds from source"

    # A fixed app whose layout is known: Settings scrolls, and scrolling is a
    # change no clock tick can fake away.
    "$SIMCTL" terminate "$BOOTED" com.apple.Preferences >/dev/null 2>&1 || true
    "$SIMCTL" launch "$BOOTED" com.apple.Preferences >/dev/null 2>&1 || true
    sleep 4
    "$SIMCTL" io "$BOOTED" screenshot /tmp/simtouch-before.png >/dev/null 2>&1

    printf '{"type":"swipe","x":0.5,"y":0.8,"x2":0.5,"y2":0.3,"ms":350}\n' \
      | "$HELPER" "$BOOTED" >/tmp/simtouch-reply.log 2>&1 || true
    sleep 2
    "$SIMCTL" io "$BOOTED" screenshot /tmp/simtouch-after.png >/dev/null 2>&1

    check "$(grep -q '"ok":true' /tmp/simtouch-reply.log && echo 1 || echo 0)" \
      "the helper accepted the gesture"

    # The real assertion. Only a changed screen proves the touch reached the
    # guest; the helper's own reply proves nothing, which is the whole point.
    if ! cmp -s /tmp/simtouch-before.png /tmp/simtouch-after.png; then
      check 1 "the gesture changed the simulator's screen"
    else
      check 0 "the gesture changed the simulator's screen (the frames are identical)"
    fi

    # A refused request must be refused loudly: an unknown device is the most
    # common failure once a simulator is shut down while a preview is open.
    if printf '{"type":"tap","x":0.5,"y":0.5}\n' | "$HELPER" 00000000-0000-0000-0000-000000000000 \
        >/tmp/simtouch-bad.log 2>&1; then
      check 0 "an unknown simulator is refused"
    else
      check 1 "an unknown simulator is refused"
    fi
  fi
fi

echo
if [ "$fail" -eq 0 ]; then
  printf 'SIMULATOR_TOUCH_PASS  (%d checks, %d skipped)\n' "$pass" "$skip"
else
  printf 'SIMULATOR_TOUCH_FAIL  (%d of %d failed, %d skipped)\n' "$fail" "$((pass + fail))" "$skip"
  exit 1
fi