#!/usr/bin/env bash
#
# Drives a terminal gesture end to end on a simulator: a binding is declared,
# the gesture is fired, and the host's own arithmetic expansion is looked for in
# the terminal. Like the typed-input and shortcut tests, the marker proves the
# *host* ran the command rather than the terminal echoing what it was handed.
#
# Why the binding is injected
# ---------------------------
# A UISwipeGestureRecognizer cannot be driven from a command line, so the
# gesture is announced through the environment and the view's own handler is
# called — the same `send(binding:)` a real swipe reaches. Everything that
# turns a gesture into bytes (the store, the grammar, the fallback) is the real
# code; only the finger is stood in for. The store itself is covered without a
# simulator by scripts/shortcut-grammar/run.sh.
#
# Usage: scripts/gesture-test.sh [gesture]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEVICE="${DEVICE:-iPhone 17}"
SEED_FILE="${SEED_FILE:-/tmp/cqut_sshd/seed.txt}"
GESTURE="${1:-swipeLeft}"
# 30+5 so the shell has to expand it; the literal never appears in the output.
MARKER="GESTURE_\$((30+5))_OK"
BINDING="text:echo $MARKER"
SHOT="${SHOT:-/tmp/cqutmux_gesture.png}"

[[ -f "$SEED_FILE" ]] || { echo "no ssh key seed at $SEED_FILE — run scripts/watch-test.sh once" >&2; exit 1; }

UDID="$(xcrun simctl list devices available | grep -m1 "$DEVICE (" | grep -oE '[0-9A-F-]{36}')"
[[ -n "$UDID" ]] || { echo "simulator '$DEVICE' not found" >&2; exit 1; }
APP="build/Build/Products/Debug-iphonesimulator/CQUTmux.app"
[[ -d "$APP" ]] || { echo "no app — build first (scripts/build.sh)" >&2; exit 1; }

echo "==> installing fresh and binding $GESTURE to $BINDING"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl terminate "$UDID" app.cqutmux.ios 2>/dev/null || true
# A saved host remembers the previous run's gateway port, and DebugSeed only
# inserts a host it has not seen; reinstalling is what makes this run clean.
xcrun simctl uninstall "$UDID" app.cqutmux.ios 2>/dev/null || true
xcrun simctl spawn "$UDID" launchctl kickstart -k system/com.apple.SpringBoard 2>/dev/null || true
sleep 3
xcrun simctl install "$UDID" "$APP"

SIMCTL_CHILD_CQUT_DEV_HOST="${CQUT_DEV_HOST:-127.0.0.1}" \
SIMCTL_CHILD_CQUT_DEV_PORT="${CQUT_DEV_PORT:-2222}" \
SIMCTL_CHILD_CQUT_DEV_USER="${CQUT_DEV_USER:-$(whoami)}" \
SIMCTL_CHILD_CQUT_DEV_KEY_SEED="$(cat "$SEED_FILE")" \
SIMCTL_CHILD_CQUT_DEV_NO_NOTIFS=1 \
SIMCTL_CHILD_CQUT_DEV_GESTURE="$GESTURE=$BINDING" \
SIMCTL_CHILD_CQUT_DEV_FIRE_GESTURE="$GESTURE" \
  xcrun simctl launch "$UDID" app.cqutmux.ios >/dev/null
sleep 18

xcrun simctl io "$UDID" screenshot "$SHOT" >/dev/null 2>&1
echo "==> screenshot: $SHOT"
echo "    PASS if the terminal shows 'GESTURE_35_OK' — the host's own expansion"
echo "    of $MARKER — rather than the command line that was sent."