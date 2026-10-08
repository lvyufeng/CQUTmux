#!/usr/bin/env bash
#
# Exercises `cqutmux://` links end to end on a simulator: the app is launched on
# a tab that is *not* the terminal, a link is handed to the app, and the
# terminal is then screenshotted. A pass is the attach command having run —
# `tmux` is deliberately not installed here, so the shell's own "command not
# found" is the evidence, and it can only appear if the link's command reached
# the pty.
#
# Why not `simctl openurl`
# ------------------------
# iOS confirms a custom-scheme launch from outside the app with an "Open in
# CQUTmux?" dialog, and nothing here can tap it: this Xcode has no Simulator.app
# and neither `cliclick` nor `idb` is installed (`simctl` itself has no input
# injection). The URL is therefore handed over through `CQUT_DEV_OPEN_URL`,
# which calls the very `onOpenURL` handler the system would. Only the OS's own
# delivery is stood in for — parsing, tab switch, host resolution, navigation
# and attach-on-connect are all the real ones.
#
# Why the app starts on another tab
# ---------------------------------
# `CQUT_DEV_HOST` makes HostsView push the terminal by itself, which would make
# any link look like it worked. Starting on Inbox means every step between the
# URL and the typed command — `onOpenURL`, the tab switch, host resolution,
# navigation, attach-on-connect — has to have happened for the marker to appear.
#
# Usage: scripts/deeplink-test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEVICE="${DEVICE:-iPhone 17}"
SEED_FILE="${SEED_FILE:-/tmp/cqut_sshd/seed.txt}"
LINK="${LINK:-cqutmux://tmux?session=cqutmux-deeplink}"
SHOT="${SHOT:-/tmp/cqutmux_deeplink.png}"

[[ -f "$SEED_FILE" ]] || { echo "no ssh key seed at $SEED_FILE — run scripts/watch-test.sh once, or set SEED_FILE" >&2; exit 1; }

UDID="$(xcrun simctl list devices available | grep -m1 "$DEVICE (" | grep -oE '[0-9A-F-]{36}')"
[[ -n "$UDID" ]] || { echo "simulator '$DEVICE' not found" >&2; exit 1; }

APP="build/Build/Products/Debug-iphonesimulator/CQUTmux.app"
[[ -d "$APP" ]] || { echo "no app — build first (scripts/build.sh)" >&2; exit 1; }

echo "==> installing and clearing the previous run"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl terminate "$UDID" app.cqutmux.ios 2>/dev/null || true
xcrun simctl uninstall "$UDID" app.cqutmux.ios 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

# A "Open in CQUTmux?" alert left un-answered by an earlier run sits over the
# app and is in the screenshot; restarting the springboard clears it. (Real
# `simctl openurl` would raise another one, which is exactly why this script
# hands the URL over through the environment instead.)
xcrun simctl spawn "$UDID" launchctl kickstart -k system/com.apple.SpringBoard 2>/dev/null || true
sleep 3

echo "==> launching on the Inbox, not the terminal, with $LINK waiting"
SIMCTL_CHILD_CQUT_DEV_HOST="${CQUT_DEV_HOST:-127.0.0.1}" \
SIMCTL_CHILD_CQUT_DEV_PORT="${CQUT_DEV_PORT:-2222}" \
SIMCTL_CHILD_CQUT_DEV_USER="${CQUT_DEV_USER:-$(whoami)}" \
SIMCTL_CHILD_CQUT_DEV_KEY_SEED="$(cat "$SEED_FILE")" \
SIMCTL_CHILD_CQUT_DEV_NO_NOTIFS=1 \
SIMCTL_CHILD_CQUT_DEV_TAB=inbox \
SIMCTL_CHILD_CQUT_DEV_OPEN_URL="$LINK" \
  xcrun simctl launch "$UDID" app.cqutmux.ios >/dev/null
# The session has to finish coming up before the attach command is sent; the
# app waits for `.connected` itself, so this only has to outlast the connect.
sleep 20

xcrun simctl io "$UDID" screenshot "$SHOT" >/dev/null 2>&1
echo "==> screenshot: $SHOT"
echo "    PASS if the terminal shows the attach command's own failure —"
echo "    'command not found: tmux' — rather than a bare prompt."