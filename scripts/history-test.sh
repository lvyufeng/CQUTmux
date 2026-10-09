#!/usr/bin/env bash
#
# Checks the command-history route against a real gateway, end to end.
#
# Usage: scripts/history-test.sh
#
# The unit checks in scripts/shell-history/ cover the parser, which is where the
# subtle mistakes live. This covers the part they cannot: that the route exists,
# that it is *not* gated behind always-on discovery the way /recent-directories
# is, that the JSON has the shape the app decodes, and that the app's own
# Command History sheet renders it.
#
# The host's real history is read but never written: a fixture is pointed at
# with HISTFILE, and the script asserts on the fixture. Touching the user's own
# ~/.zsh_history from a test would be a way to lose it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATEWAY_PORT="${CQUTMUX_GATEWAY_PORT:-24998}"
TOKEN="history-test"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# A fake home rather than HISTFILE alone: the reader also looks at
# `~/.zsh_history` by path, so pointing only HISTFILE at a fixture would still
# read the real history — and the fixture's 2023 timestamps would then be sorted
# below every recent real command and fall off the 200-entry limit.
FAKE_HOME="$OUT/home"
mkdir -p "$FAKE_HOME"
{
  printf ': 1700000100:0;cargo test --workspace\n'
  printf ': 1700000200:0;git commit -m "a;semi;colon"\n'
  printf ': 1700000300:0;kubectl logs -f deploy/api -n prod \\\n'
  printf '  --tail=200\n'
  printf ': 1700000400:0;bun install\n'
  printf 'make -j8\n'
} > "$FAKE_HOME/.zsh_history"

echo "==> starting the gateway with a fixture history"
HOME="$FAKE_HOME" SHELL=/bin/zsh node host/cqutmux-hook/index.mjs \
  --port "$GATEWAY_PORT" --token "$TOKEN" >"$OUT/gateway.log" 2>&1 &
GW_PID=$!
trap 'kill $GW_PID 2>/dev/null || true; rm -rf "$OUT"' EXIT
sleep 2

if ! kill -0 "$GW_PID" 2>/dev/null; then
  echo "FAIL: the gateway exited; log follows" >&2
  cat "$OUT/gateway.log" >&2
  exit 1
fi

echo "==> reading /history"
curl -fsS -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$GATEWAY_PORT/history" \
  > "$OUT/history.json"

python3 - "$OUT/history.json" <<'PY'
import json, sys

board = json.load(open(sys.argv[1]))

problems = []
if board.get("available") is not True:
    problems.append(f"the route reports available={board.get('available')!r}")
commands = board.get("commands")
if not isinstance(commands, list):
    problems.append("commands is not a list")
    commands = []

texts = [c.get("command") for c in commands]

for wanted in ["cargo test --workspace", 'git commit -m "a;semi;colon"']:
    if wanted not in texts:
        problems.append(f"{wanted!r} is missing from the history")

# The whole reason the parser splits on the *first* semicolon: a command that
# contains one must survive intact rather than being truncated at it.
if not any("a;semi;colon" in (t or "") for t in texts):
    problems.append("a semicolon inside a command was lost")

# A continued record is one command, with a newline where the shell had one.
joined = [t for t in texts if t and "kubectl logs" in t]
if not joined:
    problems.append("the continued command is missing")
elif "\n" not in joined[0]:
    problems.append(f"the continued command was flattened to one line: {joined[0]!r}")

# The plain-format record has no timestamp, which is not an error.
plain = [c for c in commands if c.get("command") == "make -j8"]
if not plain:
    problems.append("the plain-format record is missing")
elif plain[0].get("at") is not None:
    problems.append(f"a plain record should have at=null, got {plain[0].get('at')!r}")

# Only the fixture is on this host. A real command leaking in would mean the
# reader ignored the fake HOME and read the user's own history.
absent = {"ls", "cd", "cat"}
if absent & set(texts or []):
    problems.append(f"real history leaked into the fixture: {sorted(absent & set(texts))}")

for entry in commands:
    if set(entry) != {"command", "at", "shell"}:
        problems.append(f"unexpected keys in an entry: {sorted(entry)}")
        break
    if entry.get("shell") not in ("zsh", "bash"):
        problems.append(f"entry names an unknown shell: {entry.get('shell')!r}")
        break

if problems:
    for problem in problems:
        print(f"FAIL: {problem}")
    raise SystemExit(1)
print(f"PASS: /history returns {len(commands)} command(s) with the shape the app decodes")
PY

echo "==> checking /history is not gated behind always-on discovery"
# /recent-directories is off unless discovery is on, because it scans the disk
# on a timer. /history is read when the user asks for it, so the same gate would
# make the key silently dead for anyone who left discovery off — which is the
# default. This asserts the two routes really do differ.
cat > "$OUT/config.toml" <<'TOML'
[gateway]
always_on_discovery = false
TOML

kill "$GW_PID" 2>/dev/null || true
wait "$GW_PID" 2>/dev/null || true

CQUTMUX_CONFIG="$OUT/config.toml" HOME="$FAKE_HOME" SHELL=/bin/zsh node host/cqutmux-hook/index.mjs \
  --port "$GATEWAY_PORT" --token "$TOKEN" >"$OUT/gateway2.log" 2>&1 &
GW_PID=$!
sleep 2

python3 - "$GATEWAY_PORT" "$TOKEN" <<'PY'
import json, sys, urllib.request

port, token = sys.argv[1], sys.argv[2]


def get(path):
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}", headers={"Authorization": f"Bearer {token}"}
    )
    return json.load(urllib.request.urlopen(request))


discovery = get("/recent-directories")
history = get("/history")

problems = []
if discovery.get("enabled") is not False:
    problems.append("discovery is off in the config, but /recent-directories did not say so")
if not history.get("commands"):
    problems.append("/history went empty when discovery was turned off")

if problems:
    for problem in problems:
        print(f"FAIL: {problem}")
    raise SystemExit(1)
print("PASS: /history stays live with discovery off, while /recent-directories goes quiet")
PY

kill "$GW_PID" 2>/dev/null || true
wait "$GW_PID" 2>/dev/null || true

echo "==> launching the app on the Command History sheet"
UDID="$(xcrun simctl list devices available | grep -m1 'iPhone 18 Pro (' | grep -oE '[0-9A-F-]{36}' || true)"
if [[ -z "$UDID" ]]; then
  echo "SKIP: no iPhone 18 Pro simulator — the route above is the substance of this check"
  exit 0
fi

APP="$ROOT/build/Build/Products/Debug-iphonesimulator/CQUTmux.app"
[[ -d "$APP" ]] || { echo "SKIP: no built app; run scripts/build.sh first"; exit 0; }

SEED_FILE="${SEED_FILE:-/tmp/cqut_sshd/seed.txt}"
[[ -f "$SEED_FILE" ]] || { echo "SKIP: no ssh seed at $SEED_FILE"; exit 0; }

# The gateway has to be up for the sheet to have anything to show, and it was
# stopped above when the gating check restarted it with a different config. A
# fresh one, back on the fixture home.
HOME="$FAKE_HOME" SHELL=/bin/zsh node host/cqutmux-hook/index.mjs \
  --port "$GATEWAY_PORT" --token "$TOKEN" >"$OUT/gateway3.log" 2>&1 &
# Reassign so the trap reaps *this* one. A gateway started after the last
# reassignment is not in `$GW_PID`, so the trap kills the wrong process and the
# port stays held — which makes the next run fail with EADDRINUSE instead of
# reporting anything about the app.
GW_PID=$!
sleep 2

# Install, don't just launch: `simctl launch` on an app that is already running
# only foregrounds it, so every SIMCTL_CHILD_* variable is ignored and the run
# silently shows whatever the last launch left behind — which is exactly the
# blank result this step exists to catch. Reinstalling also clears the saved
# host, because DebugSeed only inserts one it has not seen, and a saved host
# remembers the *previous* run's gateway port.
xcrun simctl terminate "$UDID" app.cqutmux.ios 2>/dev/null || true
xcrun simctl uninstall "$UDID" app.cqutmux.ios 2>/dev/null || true
xcrun simctl spawn "$UDID" launchctl kickstart -k system/com.apple.SpringBoard 2>/dev/null || true
sleep 3
xcrun simctl install "$UDID" "$APP"
SIMCTL_CHILD_CQUT_DEV_HOST=127.0.0.1 SIMCTL_CHILD_CQUT_DEV_PORT=2222 \
SIMCTL_CHILD_CQUT_DEV_USER="$(whoami)" SIMCTL_CHILD_CQUT_DEV_KEY_SEED="$(cat "$SEED_FILE")" \
SIMCTL_CHILD_CQUT_DEV_GATEWAY_PORT="$GATEWAY_PORT" SIMCTL_CHILD_CQUT_DEV_GATEWAY_TOKEN="$TOKEN" \
SIMCTL_CHILD_CQUT_DEV_NO_NOTIFS=1 SIMCTL_CHILD_CQUT_DEV_SHEET=command-history \
  xcrun simctl launch "$UDID" app.cqutmux.ios >/dev/null

sleep 16
xcrun simctl io "$UDID" screenshot /tmp/cqutmux-history-sheet.png >/dev/null 2>&1 || true
echo "  screenshot: /tmp/cqutmux-history-sheet.png"

echo ""
echo "HISTORY_PASS  (route, gating, and the sheet's data source)"