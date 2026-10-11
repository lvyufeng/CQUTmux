#!/usr/bin/env bash
#
# Proves a Live Activity actually starts and its widget renders, on a booted
# simulator — the half the rule-level checks cannot reach.
#
# Usage: scripts/liveactivity-delivery-check.sh
#
# What is asserted, and why this script exists
# --------------------------------------------
# `scripts/liveactivity/check.mjs` asserts the *decision* and the *payload*: what
# the host decides an event needs, and the exact JSON it would send. What it
# cannot assert is the one call in this feature that can fail quietly —
# `Activity.request`. The system's activity budget, an activity already on
# screen, and Live Activities switched off for the app all end in a *throw* that
# never reaches the UI; the activity is simply not there, and a payload check
# stays green through all of it.
#
# So this runs the app on a simulator with `CQUT_DEV_TEST_ACTIVITY=1`, which
# starts an activity from launch and reports the outcome (`RootView.swift`). The
# button that does the same thing by hand cannot be tapped by `simctl`; this env
# hook is that button's own code path, reached without a tap.
#
# The boundary, stated honestly
# -----------------------------
# This proves the app end: `Activity.request` succeeded and the widget extension
# was launched to render it. It does NOT prove *push delivery* — that a payload
# from APNs starts or updates an activity on a suspended app. `xcrun simctl push`
# does not carry Live Activity pushes: its own help says "Only application remote
# push notifications are supported", with liveactivity explicitly outside that.
# Delivery needs an `aps-environment` entitlement (a paid provisioning profile)
# and a physical device, so it stays unverified here and is recorded as such —
# this script narrows the gap, it does not close it.
#
# Reading the outcome
# -------------------
# The app reports the outcome with a `Logger` line (not only `print`), and this
# script reads it from the *unified log*. Two traps made a started activity read
# as "no activity" first:
#   - `print` to a pipe is block-buffered, so following `simctl launch` and then
#     killing it loses the unflushed line. The `Logger` line is flushed as it is
#     written and survives the app being terminated.
#   - piping `log show` straight into `grep -q`/`-m1` is fragile under
#     `set -o pipefail`: the reader exiting at its first match kills `log show`
#     with SIGPIPE, the pipeline goes non-zero, and a *match* reads as no match.
#     So the log is dumped to a file first and the file is grepped — no pipe from
#     a long-running reader to break.
#
# Mutation-testing this check
# ---------------------------
# Break `Activity.request` (e.g. start a second activity so the system rejects
# it) and the `started` assertion goes red with the thrown reason — which is
# exactly the failure this check is here to catch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEVICE="${DEVICE:-iPhone 18 Pro}"
BUNDLE="app.cqutmux.ios"
TMP="${CLAUDE_JOB_DIR:-/tmp}/tmp"
mkdir -p "$TMP"
LAUNCH_LOG="$TMP/liveactivity-launch.log"
SYSLOG="$TMP/liveactivity-syslog.txt"

# Dumps this device's log to a file so callers grep a file, not a pipe.
dump_syslog() { xcrun simctl spawn "$UDID" log show --last "${1:-5m}" > "$SYSLOG" 2>/dev/null || true; }

echo "==> building (Debug — the test hook is #if DEBUG)"
"$ROOT/scripts/build.sh" >/dev/null

APP="$(find build/Build/Products -name 'CQUTmux.app' -maxdepth 3 | head -1)"
[ -n "$APP" ] || { echo "FAIL  no built app"; exit 1; }
echo "PASS  built the app"

# The widget extension has to be embedded, or the activity starts with nothing
# to render it — a pass on the app half that still shows the user no widget.
[ -d "$APP/PlugIns/CQUTmuxWidgets.appex" ] \
  || { echo "FAIL  widget extension is not embedded"; exit 1; }
echo "PASS  the widget extension is embedded"

UDID="$(xcrun simctl list devices available | grep -m1 "$DEVICE (" | grep -oE '[0-9A-F-]{36}')"
[ -n "$UDID" ] || { echo "FAIL  simulator '$DEVICE' not found"; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null || true
echo "PASS  simulator present ($DEVICE)"

xcrun simctl install "$UDID" "$APP" >/dev/null
echo "PASS  app installed"

# Start from a clean slate: an activity the previous run left on screen makes
# the next `Activity.request` throw "already active", which would read as a
# failure of the feature rather than of the harness.
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
sleep 1

: > "$LAUNCH_LOG"
SIMCTL_CHILD_CQUT_DEV_TEST_ACTIVITY=1 \
SIMCTL_CHILD_CQUT_DEV_NO_CONNECT=1 \
SIMCTL_CHILD_CQUT_DEV_NO_NOTIFS=1 \
  xcrun simctl launch "$UDID" "$BUNDLE" >> "$LAUNCH_LOG" 2>&1

# Polled: the line lands a moment after launch. Read from the file dump, so a
# match is a match regardless of `pipefail`.
OUTCOME=""
for _ in $(seq 1 30); do
  dump_syslog 2m
  OUTCOME="$(sed -n 's/.*CQUT_TEST_ACTIVITY: //p' "$SYSLOG" | head -1 | tr -d '\r' || true)"
  [ -n "$OUTCOME" ] && break
  sleep 1
done

[ -n "$OUTCOME" ] || { echo "FAIL  the app logged no activity outcome"; exit 1; }
echo "PASS  the app reported an outcome: $OUTCOME"

# `started` is the only success; `unavailable` (system) and `disabledInApp`
# (switch off) are distinct fixes, and `failed(reason)` carries the throw.
[ "$OUTCOME" = "started" ] \
  || { echo "FAIL  Activity.request did not start an activity ($OUTCOME)"; exit 1; }
echo "PASS  Activity.request started the activity at runtime"

# The widget extension is a separate process; the system launches it only when
# there is an activity to render. Its launch is the render half of the proof.
#
# Polled, and given room: which instant the system brings the extension up is its
# own schedule, not ours — observed tens of seconds after launch, so a check that
# looked once at 15s reported "never launched" about a run that rendered fine.
WIDGET_LAUNCHES=0
for _ in $(seq 1 45); do
  dump_syslog 5m
  WIDGET_LAUNCHES="$(grep -a -c 'CQUTmuxWidgets.*launched' "$SYSLOG" || true)"
  [ "${WIDGET_LAUNCHES:-0}" -gt 0 ] 2>/dev/null && break
  sleep 2
done
[ "${WIDGET_LAUNCHES:-0}" -gt 0 ] 2>/dev/null \
  || { echo "FAIL  the widget extension never launched"; exit 1; }
echo "PASS  the widget extension was launched to render it"

echo ""
echo "LIVEACTIVITY_DELIVERY_PASS (6 checks)"
echo "NOTE  app-side verified; APNs push *delivery* still needs a device + profile"