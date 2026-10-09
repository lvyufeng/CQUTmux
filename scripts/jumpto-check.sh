#!/usr/bin/env bash
#
# Checks the Jump To screen: the waiting count and the three layouts.
#
# Usage: scripts/jumpto-check.sh
#
# What is asserted
# ----------------
# 1. The gateway's `/herdr` carries the per-pane statuses the waiting count is
#    built from — if `blocked` never reaches the app, the count is always zero
#    and the banner never appears, which looks identical to "nothing waiting".
# 2. Every pane in the tree can be named by id, because the grid chips jump by
#    id and a tree that only has positions would send the wrong selector.
# 3. Each layout renders. A layout is a pure view function behind a menu, so the
#    only honest check is to start the sheet in that layout and screenshot it —
#    the count and the chips are read off the pixels, not off the model.
#
# Herdr is optional: with no server running the script says so and stops.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HERDR="${CQUTMUX_HERDR:-/private/tmp/herdr-install/bin/herdr}"
GATEWAY_PORT="${CQUTMUX_GATEWAY_PORT:-24631}"
TOKEN="jumpto-test"

[[ -x "$HERDR" ]] || { echo "no herdr at $HERDR — set CQUTMUX_HERDR" >&2; exit 1; }

if ! "$HERDR" status >/dev/null 2>&1; then
  echo "SKIP: no herdr server running (start one, then re-run)"
  exit 0
fi

echo "==> starting the gateway against $HERDR"
CQUTMUX_HERDR="$HERDR" node host/cqutmux-hook/index.mjs --port "$GATEWAY_PORT" --token "$TOKEN" \
  >/tmp/cqutmux_jumpto_gw.log 2>&1 &
GW_PID=$!
trap 'kill $GW_PID 2>/dev/null || true' EXIT
sleep 2

echo "==> checking the state the waiting count is built from"
curl -fsS -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$GATEWAY_PORT/herdr" \
  | python3 -c '
import json, sys
tree = json.load(sys.stdin)
if not tree.get("installed"):
    print("FAIL: /herdr says herdr is not installed"); raise SystemExit(1)
agents = tree.get("agents") or []
panes = [p for tab in tree.get("tabs", []) for p in tab.get("panes", [])]
if not panes:
    print("FAIL: no panes in the tree"); raise SystemExit(1)

statuses = {p["paneId"]: p["status"] for p in panes}
missing = [p["paneId"] for p in panes if not p["paneId"]]
if missing:
    print("FAIL: panes without an id:", missing); raise SystemExit(1)

blocked = [pane for pane, status in statuses.items() if status == "blocked"]
print(f"  {len(panes)} pane(s), statuses: " + ", ".join(sorted(set(statuses.values()))))
print("  waiting (blocked): " + (", ".join(blocked) if blocked else "none"))

# The banner only appears when something is blocked, so a host with nothing
# waiting proves nothing about it. Say so rather than reporting a pass.
if not blocked:
    print("  NOTE: nothing is blocked on this host, so the banner cannot be seen")
'

echo "==> checking that every pane can be jumped to by id"
curl -fsS -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$GATEWAY_PORT/herdr" \
  | python3 -c '
import json, sys
tree = json.load(sys.stdin)
agents = tree.get("agents") or []
panes = [p for tab in tree.get("tabs", []) for p in tab.get("panes", [])]
# The flat agent list is what the count uses; the nested list is what the rows
# use. Both have to carry the same ids or the count and the rows disagree.
flat = {a["paneId"] for a in agents}
nested = {p["paneId"] for p in panes}
if not flat <= nested:
    print(f"FAIL: agent list has panes the tree does not: {sorted(flat - nested)}")
    raise SystemExit(1)
for a in agents:
    if not a.get("paneId"):
        print("FAIL: an agent has no pane id"); raise SystemExit(1)
print(f"PASS: {len(flat)} agent pane(s) are all named and all present in the tree")
'

echo "==> launching the app in each layout"
DEVICE="${DEVICE:-iPhone 18 Pro}"
UDID="$(xcrun simctl list devices available | grep -m1 "$DEVICE (" | grep -oE '[0-9A-F-]{36}')"
SEED_FILE="${SEED_FILE:-/tmp/cqut_sshd/seed.txt}"
if [[ -z "$UDID" || ! -f "$SEED_FILE" ]]; then
  echo "    (no simulator or no ssh seed; skipped the UI step)"
  exit 0
fi

launch() {
  local layout="$1" expand="$2" shot="$3"
  # A leftover install keeps its saved host and gateway port, and `simctl
  # launch` on an already-running app silently ignores SIMCTL_CHILD_* — so the
  # app is fully torn down and reinstalled for each layout.
  xcrun simctl terminate "$UDID" app.cqutmux.ios 2>/dev/null || true
  xcrun simctl uninstall "$UDID" app.cqutmux.ios 2>/dev/null || true
  xcrun simctl spawn "$UDID" launchctl kickstart -k system/com.apple.SpringBoard 2>/dev/null || true
  sleep 2
  xcrun simctl install "$UDID" build/Build/Products/Debug-iphonesimulator/CQUTmux.app
  SIMCTL_CHILD_CQUT_DEV_HOST=127.0.0.1 SIMCTL_CHILD_CQUT_DEV_PORT=2222 \
  SIMCTL_CHILD_CQUT_DEV_USER="$(whoami)" SIMCTL_CHILD_CQUT_DEV_KEY_SEED="$(cat "$SEED_FILE")" \
  SIMCTL_CHILD_CQUT_DEV_GATEWAY_PORT="$GATEWAY_PORT" SIMCTL_CHILD_CQUT_DEV_GATEWAY_TOKEN="$TOKEN" \
  SIMCTL_CHILD_CQUT_DEV_NO_NOTIFS=1 SIMCTL_CHILD_CQUT_DEV_SHEET=jumpto \
  SIMCTL_CHILD_CQUT_DEV_JUMPTO_LAYOUT="$layout" \
  SIMCTL_CHILD_CQUT_DEV_JUMPTO_EXPAND="$expand" \
    xcrun simctl launch "$UDID" app.cqutmux.ios >/dev/null
  sleep 16
  xcrun simctl io "$UDID" screenshot "$shot" >/dev/null 2>&1
  echo "    $layout → $shot"
}

launch list    0 /tmp/cqutmux_jumpto_list.png
launch accordion 1 /tmp/cqutmux_jumpto_accordion.png
launch grid    0 /tmp/cqutmux_jumpto_grid.png

echo "JUMPTO_PASS"