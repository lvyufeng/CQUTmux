#!/usr/bin/env bash
#
# Checks the tab quick-access row: which bytes each of the twenty buttons sends,
# per multiplexer, and that the row is only drawn where it has somewhere to send.
#
# Usage: scripts/tab-row-check.sh
#
# Two halves, because they fail differently
# -----------------------------------------
# The *mapping* is pure, so it is checked without a simulator by running the real
# `MuxSettings.MuxCommand.selectTab` through the Swift interpreter. That is where
# the interesting part lives: three multiplexers with three different mechanisms
# under one row of twenty buttons, and the failure mode — a button that types a
# digit into whatever program is running — is invisible unless the bytes are read.
#
# The *delivery* is checked on a booted simulator against a real sshd: the app is
# launched on a host whose `cat -v` is running, a tab number is pressed through the
# view's own `selectTab`, and the host's output is screenshotted. `cat -v` renders
# the prefix as `^B`, so a digit that arrived without its prefix — the bug this
# whole row can have — is visible as a bare `1` rather than a silently-ignored
# keystroke.
#
# The row's buttons sit in a scroll view above the keyboard, so a script cannot
# tap one; that is why the press goes through `CQUT_DEV_TAB`, which calls the
# very method the button's action calls.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
check() { # <condition> <label>
  if [ "$1" = "1" ]; then
    printf 'PASS  %s\n' "$2"
  else
    printf 'FAIL  %s\n' "$2"
    fail=1
  fi
}
note() { printf 'SKIP  %s\n' "$1"; }

echo "==> the row's mapping, without a simulator"

MUX_TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$MUX_TEST_DIR"' EXIT

swiftc -O -o "$MUX_TEST_DIR/row" \
  "$ROOT/App/Features/Terminal/MuxSettings.swift" \
  "$ROOT/scripts/tab-row/main.swift"

"$MUX_TEST_DIR/row" | tee "$MUX_TEST_DIR/results"
if grep -q '^FAIL' "$MUX_TEST_DIR/results"; then fail=1; fi

echo "==> the row is wired into the view"
check "$(grep -q 'tabRowApplies, !input.hidesWindowRow { tabRow }' \
  App/Features/Terminal/TerminalViewRepresentable.swift && echo 1 || echo 0)" \
  "the row is drawn behind the hide toggle"
check "$(grep -q 'ForEach(MuxSettings.MuxCommand.selectableTabs' \
  App/Features/Terminal/TerminalViewRepresentable.swift && echo 1 || echo 0)" \
  "the row draws every selectable tab, from one source of truth"
# The row used to be gated to `host.mux == "tmux"` and hard-coded to tmux. A
# regression to that would leave the row missing on herdr and zellij, which is
# exactly the gap this closed.
check "$(grep -q 'host.mux == \"tmux\", !input.hidesWindowRow' \
  App/Features/Terminal/TerminalViewRepresentable.swift && echo 0 || echo 1)" \
  "the row is no longer gated to tmux alone"

echo "==> the row on a live host"

SEED_FILE="${SEED_FILE:-/tmp/cqut_sshd/seed.txt}"
if [ ! -f "$SEED_FILE" ]; then
  note "no ssh fixture at $SEED_FILE — the end-to-end half did not run"
elif ! lsof -nP -iTCP:2222 -sTCP:LISTEN >/dev/null 2>&1; then
  note "no sshd on 127.0.0.1:2222 — the end-to-end half did not run"
elif [ ! -d "build/Build/Products/Debug-iphonesimulator/CQUTmux.app" ]; then
  note "no built app — run scripts/build.sh (the end-to-end half did not run)"
else
  DEVICE="${DEVICE:-iPhone 17}"
  UDID="$(xcrun simctl list devices available | grep -m1 "$DEVICE (" | grep -oE '[0-9A-F-]{36}')"
  SHOT="${SHOT:-/tmp/cqutmux_tab_row.png}"
  if [ -z "$UDID" ]; then
    note "simulator '$DEVICE' not found — the end-to-end half did not run"
  else
    APP="build/Build/Products/Debug-iphonesimulator/CQUTmux.app"
    xcrun simctl boot "$UDID" 2>/dev/null || true
    xcrun simctl terminate "$UDID" app.cqutmux.ios 2>/dev/null || true
    xcrun simctl uninstall "$UDID" app.cqutmux.ios 2>/dev/null || true
    xcrun simctl install "$UDID" "$APP"

    # `cat -v` renders the prefix byte as `^B`, so the digit's prefix is visible
    # in the screenshot instead of being a control byte nothing displays. The
    # tab number is 5 rather than 1 so the marker cannot be confused with the
    # row's own button labels.
    SIMCTL_CHILD_CQUT_DEV_HOST=127.0.0.1 \
    SIMCTL_CHILD_CQUT_DEV_PORT=2222 \
    SIMCTL_CHILD_CQUT_DEV_USER="$(whoami)" \
    SIMCTL_CHILD_CQUT_DEV_KEY_SEED="$(cat "$SEED_FILE")" \
    SIMCTL_CHILD_CQUT_DEV_NO_NOTIFS=1 \
    SIMCTL_CHILD_CQUT_DEV_TYPE='cat -v; echo TAB_READY' \
    SIMCTL_CHILD_CQUT_DEV_TAB=5 \
    SIMCTL_CHILD_CQUT_DEV_TAB_MUX=tmux \
      xcrun simctl launch "$UDID" app.cqutmux.ios >/dev/null
    # The typed command runs first and the tab press follows it after the seed's
    # own delay, so this only has to outlast both.
    sleep 20
    xcrun simctl io "$UDID" screenshot "$SHOT" >/dev/null 2>&1
    echo "    screenshot: $SHOT"
    echo "    PASS if it shows '^B5' on the cat -v line — the prefix and the digit,"
    echo "    in that order — and not a bare '5'."
  fi
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "TAB_ROW_PASS"
else
  echo "TAB_ROW_FAIL"
  exit 1
fi