#!/usr/bin/env bash
#
# Checks the herdr half of the session picker against a real herdr server.
#
# Usage: scripts/herdr-test.sh
#
# What is asserted
# ----------------
# 1. The gateway folds herdr workspaces into `/sessions` with `mux: "herdr"`.
# 2. Every tab the snapshot has is listed — *including tabs with no agent in
#    them*, which is the bug this script exists to catch: deriving the tab list
#    from the agents array silently dropped them.
# 3. `herdr tab focus <tab_id>` really moves the focused tab, so the selector
#    the picker sends is one the server acts on.
#
# The app is launched on the Sessions sheet afterwards for a look; on a device
# without a herdr server the script says so and stops rather than failing, since
# herdr is optional.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HERDR="${CQUTMUX_HERDR:-/private/tmp/herdr-install/bin/herdr}"
GATEWAY_PORT="${CQUTMUX_GATEWAY_PORT:-24611}"
TOKEN="herdr-test"

[[ -x "$HERDR" ]] || { echo "no herdr at $HERDR — set CQUTMUX_HERDR" >&2; exit 1; }

if ! "$HERDR" status >/dev/null 2>&1; then
  echo "SKIP: no herdr server running (start one, then re-run)"
  exit 0
fi

echo "==> starting the gateway against $HERDR"
CQUTMUX_HERDR="$HERDR" node host/cqutmux-hook/index.mjs --port "$GATEWAY_PORT" --token "$TOKEN" \
  >/tmp/cqutmux_herdr_gw.log 2>&1 &
GW_PID=$!
# The gateway outlives this script only if the script dies badly; trap covers
# the normal and the interrupted exits.
trap 'kill $GW_PID 2>/dev/null || true' EXIT
sleep 2

echo "==> folding herdr into /sessions"
curl -fsS -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$GATEWAY_PORT/sessions" \
  | python3 -c '
import json, sys
board = json.load(sys.stdin)
herdr = [s for s in board["sessions"] if s["mux"] == "herdr"]
if not herdr:
    print("FAIL: no herdr sessions in the board"); raise SystemExit(1)
for session in herdr:
    name, status, windows = session["name"], session.get("status"), session["windowList"]
    print(f"  {name}  status={status}  tabs={len(windows)}")
    for window in windows:
        print("    selector={}  name={}".format(window["selector"], window["name"]))
'

echo "==> comparing against herdr's own tab list"
"$HERDR" api snapshot >/tmp/cqutmux_herdr_snapshot.json
python3 - "$GATEWAY_PORT" "$TOKEN" <<'PY'
import json, sys, urllib.request

port, token = sys.argv[1], sys.argv[2]
request = urllib.request.Request(
    f"http://127.0.0.1:{port}/sessions", headers={"Authorization": f"Bearer {token}"}
)
board = json.load(urllib.request.urlopen(request))

snapshot = json.load(open("/tmp/cqutmux_herdr_snapshot.json"))["result"]["snapshot"]
by_workspace = {}
for tab in snapshot.get("tabs", []):
    by_workspace.setdefault(tab["workspace_id"], []).append(tab["tab_id"])

labels = {w["workspace_id"]: (w.get("label") or w["workspace_id"]) for w in snapshot.get("workspaces", [])}

problems = []
for session in [s for s in board["sessions"] if s["mux"] == "herdr"]:
    expected = set(by_workspace.get(
        next((wid for wid, label in labels.items() if label == session["name"]), None), []
    ))
    got = {w["selector"] for w in session["windowList"]}
    if expected != got:
        problems.append(f"{session['name']}: expected tabs {sorted(expected)}, got {sorted(got)}")

if problems:
    for problem in problems:
        print(f"FAIL: {problem}")
    raise SystemExit(1)
print(f"PASS: every herdr tab is listed, across {len(by_workspace)} workspace(s)")
PY

echo "==> checking that a tab selector actually moves the focused tab"
TAB="$(python3 -c '
import json
snapshot = json.load(open("/tmp/cqutmux_herdr_snapshot.json"))["result"]["snapshot"]
tabs = snapshot.get("tabs", [])
print(tabs[0]["tab_id"] if tabs else "")
')"
if [[ -z "$TAB" ]]; then
  echo "SKIP: no tabs to focus"
else
  "$HERDR" tab focus "$TAB" >/dev/null
  FOCUSED="$("$HERDR" api snapshot | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["snapshot"].get("focused_tab_id",""))')"
  [[ "$FOCUSED" == "$TAB" ]] \
    && echo "PASS: herdr tab focus $TAB moved the focused tab" \
    || { echo "FAIL: focused tab is $FOCUSED, not $TAB"; exit 1; }
fi

echo "==> launching the app on the Sessions sheet"
DEVICE="${DEVICE:-iPhone 17}"
UDID="$(xcrun simctl list devices available | grep -m1 "$DEVICE (" | grep -oE '[0-9A-F-]{36}')"
SEED_FILE="${SEED_FILE:-/tmp/cqut_sshd/seed.txt}"
if [[ -n "$UDID" && -f "$SEED_FILE" ]]; then
  # A leftover install keeps its saved host, and the saved host remembers the
  # *previous* run's gateway port — `DebugSeed` only inserts a host it has not
  # seen. Reinstalling is what makes this run use the port chosen above.
  xcrun simctl terminate "$UDID" app.cqutmux.ios 2>/dev/null || true
  xcrun simctl uninstall "$UDID" app.cqutmux.ios 2>/dev/null || true
  # A permission dialog raised by an earlier run sits over the app and lands in
  # the screenshot; restarting the springboard dismisses it.
  xcrun simctl spawn "$UDID" launchctl kickstart -k system/com.apple.SpringBoard 2>/dev/null || true
  sleep 3
  xcrun simctl install "$UDID" build/Build/Products/Debug-iphonesimulator/CQUTmux.app
  SIMCTL_CHILD_CQUT_DEV_HOST=127.0.0.1 SIMCTL_CHILD_CQUT_DEV_PORT=2222 \
  SIMCTL_CHILD_CQUT_DEV_USER="$(whoami)" SIMCTL_CHILD_CQUT_DEV_KEY_SEED="$(cat "$SEED_FILE")" \
  SIMCTL_CHILD_CQUT_DEV_GATEWAY_PORT="$GATEWAY_PORT" SIMCTL_CHILD_CQUT_DEV_GATEWAY_TOKEN="$TOKEN" \
  SIMCTL_CHILD_CQUT_DEV_NO_NOTIFS=1 SIMCTL_CHILD_CQUT_DEV_SHEET=sessions \
    xcrun simctl launch "$UDID" app.cqutmux.ios >/dev/null
  sleep 18
  xcrun simctl io "$UDID" screenshot /tmp/cqutmux_herdr.png >/dev/null 2>&1
  echo "    screenshot: /tmp/cqutmux_herdr.png"
else
  echo "    (no simulator or no ssh seed; skipped the UI step)"
fi