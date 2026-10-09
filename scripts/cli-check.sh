#!/usr/bin/env bash
#
# Checks the host CLI: every subcommand answers, and — the part that matters —
# running with no subcommand still starts the gateway.
#
# That regression is the reason this exists. The gateway is what the app
# already calls, and a dispatcher added on top of it can silently change what a
# bare invocation means. Two bugs of exactly that shape showed up the first
# time this ran: `--port 24880` made the port look like a positional path, and
# `serve` returned instead of falling through and started nothing.
#
# Usage: scripts/cli-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/host/cqutmux-hook/index.mjs"
PORT="${CQUT_CLI_PORT:-24897}"
OUT="$(mktemp -d)"
PASS=0

cleanup() {
  # By pattern, not by the background job's pid: `node ... &` in a compound
  # command records the subshell, so killing `$!` can leave node itself running
  # and holding the port. That is what made an earlier run of this script fail
  # against a server it had started in the previous one.
  pkill -f "cqutmux-hook/index.mjs" 2>/dev/null || true
  rm -rf "$OUT"
}
trap cleanup EXIT

ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; exit 1; }

# A subcommand with no side effects and a stable exit code.
run() { node "$CLI" "$@"; }

# MARK: - The one that must not change

# No subcommand: this is the gateway, and it has to still be the gateway.
node "$CLI" --port "$PORT" > "$OUT/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 20); do
  grep -q listening "$OUT/server.log" 2>/dev/null && break
  sleep 0.25
done
grep -q "listening on 127.0.0.1:$PORT" "$OUT/server.log" \
  || fail "bare invocation no longer starts the gateway"
ok "bare invocation still starts the gateway"

# And a flag's value must not be read as a positional argument.
grep -q "no such directory" "$OUT/server.log" \
  && fail "--port's value was treated as a directory"
ok "--port's value is not mistaken for a path"

HEALTH="$(curl -s -m 3 "http://127.0.0.1:$PORT/health")"
echo "$HEALTH" | grep -q '"ok":true' || fail "the gateway is not answering /health"
ok "the gateway answers /health"

# MARK: - serve is the same thing spelled out

# `node` directly, not the `run` function: a function call in the background
# records the subshell's pid, so killing `$!` can leave node itself running and
# holding the port for the rest of the run.
node "$CLI" serve --port "$((PORT + 1))" > "$OUT/serve.log" 2>&1 &
SERVE_PID=$!
for _ in $(seq 1 20); do
  grep -q listening "$OUT/serve.log" 2>/dev/null && break
  sleep 0.25
done
# A fresh port, so this must genuinely bind — a shared port would let an
# EADDRINUSE pass for success and hide `serve` starting nothing, which is the
# bug this check was written for.
grep -q "listening on 127.0.0.1:$((PORT + 1))" "$OUT/serve.log" \
  || fail "serve did not start the gateway"
curl -s -m 3 "http://127.0.0.1:$((PORT + 1))/health" | grep -q '"ok":true' \
  || fail "serve started something that is not answering"
# This one only: the gateway on $PORT is still needed below.
kill "$SERVE_PID" 2>/dev/null || true
ok "serve starts the gateway"

# MARK: - Read-only subcommands

run help > "$OUT/help.txt" 2>&1 || fail "help exited non-zero"
grep -q "cqutmux <dir>" "$OUT/help.txt" || fail "help does not describe the path form"
grep -q "serve" "$OUT/help.txt" || fail "help does not list serve"
ok "help lists the commands"

run pair > "$OUT/pair.txt" 2>&1 || fail "pair exited non-zero"
grep -q "Port" "$OUT/pair.txt" || fail "pair does not print the port"
grep -q "Token" "$OUT/pair.txt" || fail "pair does not mention the token"
# The token warning is the point of the command: silence here would let someone
# expose event history without noticing.
grep -q "none set" "$OUT/pair.txt" || fail "pair does not warn about a missing token"
ok "pair prints host, port and the token warning"

run status --port "$PORT" > "$OUT/status.txt" 2>&1 || fail "status exited non-zero against a live gateway"
grep -q "running on" "$OUT/status.txt" || fail "status did not find the running gateway"
ok "status finds a running gateway"

# A dead port must be reported as dead, not as an empty success. Its own port,
# not one this script just used — a value close to a live port is how the
# earlier version of this check passed against a still-running `serve`.
DEAD_PORT=$((PORT + 2))
if lsof -ti ":$DEAD_PORT" >/dev/null 2>&1; then
  fail "port $DEAD_PORT is in use; the dead-port check cannot mean anything"
fi
if run status --port "$DEAD_PORT" > "$OUT/dead.txt" 2>&1; then
  fail "status succeeded against a port with nothing on it"
fi
grep -q "no gateway" "$OUT/dead.txt" || fail "status did not say the gateway was missing"
ok "status reports a missing gateway and exits non-zero"

run doctor > "$OUT/doctor.txt" 2>&1 || true   # non-zero is expected without tmux
grep -qE "^(ok|FAIL)  (tmux|git|ssh)" "$OUT/doctor.txt" || fail "doctor checked none of its tools"
grep -qE "^(ok|FAIL)  gateway" "$OUT/doctor.txt" || fail "doctor did not check the gateway"
ok "doctor checks the tools and the gateway"

run install > "$OUT/install.txt" 2>&1 || fail "install exited non-zero"
grep -q "loopback" "$OUT/install.txt" || fail "install does not say the port stays off the network"
ok "install explains how to keep the gateway running"

# MARK: - install wiring agent hooks
#
# Against a throwaway HOME: the real one belongs to whoever runs this, and an
# installer that rewrites it is exactly what these checks are here to prevent.

FAKE_HOME="$OUT/home"
mkdir -p "$FAKE_HOME/.claude"
cat > "$FAKE_HOME/.claude/settings.json" <<'JSON'
{
  "model": "opus",
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "/usr/local/bin/theirs.sh" }] }
    ]
  }
}
JSON

HOME="$FAKE_HOME" run install --dry-run > "$OUT/dryrun.txt" 2>&1 || fail "install --dry-run exited non-zero"
grep -q "would write" "$OUT/dryrun.txt" || fail "--dry-run did not say it was a rehearsal"
grep -q "theirs.sh" "$OUT/dryrun.txt" || fail "--dry-run would drop the user's own hook"
grep -q '"model": "opus"' "$FAKE_HOME/.claude/settings.json" || fail "--dry-run modified the file"
ok "install --dry-run writes nothing"

HOME="$FAKE_HOME" run install > "$OUT/install2.txt" 2>&1 || fail "install exited non-zero"
python3 -I -c "
import json, sys
d = json.load(open('$FAKE_HOME/.claude/settings.json'))
pre = d['hooks']['PreToolUse']
assert d['model'] == 'opus', 'unrelated settings were dropped'
assert any('theirs.sh' in h['command'] for g in pre for h in g['hooks']), 'the user hook was dropped'
assert any('cqutmux' in h['command'] for g in pre for h in g['hooks']), 'our hook was not added'
assert len(pre) == 2, f'expected 2 PreToolUse groups, got {len(pre)}'
assert len(d['hooks']['Stop']) == 1, 'the Stop hook was not installed'
" || fail "install did not merge cleanly into the user's config"
ok "install adds its hooks and keeps the user's"

[ -f "$FAKE_HOME/.claude/settings.json.cqutmux-backup" ] || fail "install left no backup"
ok "install backs up the file it edits"

HOME="$FAKE_HOME" run install > /dev/null 2>&1 || fail "a second install exited non-zero"
python3 -I -c "
import json
d = json.load(open('$FAKE_HOME/.claude/settings.json'))
pre = d['hooks']['PreToolUse']
assert len(pre) == 2, f'installing twice duplicated the hooks: {len(pre)} groups'
" || fail "install is not idempotent"
ok "installing twice does not stack duplicate hooks"

# A config that does not parse is the user's, and guessing at it risks losing
# their work — so the only safe thing is to refuse and say why.
BAD_HOME="$OUT/badhome"
mkdir -p "$BAD_HOME/.claude"
echo '{ broken' > "$BAD_HOME/.claude/settings.json"
if HOME="$BAD_HOME" run install > "$OUT/bad.txt" 2>&1; then
  fail "install succeeded against a file it could not parse"
fi
grep -q "not valid JSON" "$OUT/bad.txt" || fail "install did not explain the parse failure"
[ "$(cat "$BAD_HOME/.claude/settings.json")" = '{ broken' ] || fail "install rewrote a file it could not parse"
ok "install refuses a config it cannot parse, and leaves it alone"

# MARK: - The config file

# A throwaway HOME so the real ~/.config is never involved.
CFG_HOME="$OUT/cfghome"
mkdir -p "$CFG_HOME/.config/cqutmux"
CFG_PORT=$((PORT + 3))
cat > "$CFG_HOME/.config/cqutmux/config.toml" <<'TOML'
# comment, ignored
[gateway]
suppress_nested_agent_push = true
scan_ports = [3000, "5173", "8000-8010"]
usage_collection = false
TOML

HOME="$CFG_HOME" node "$CLI" --port "$CFG_PORT" > "$OUT/cfg.log" 2>&1 &
CFG_PID=$!
for _ in $(seq 1 20); do
  grep -q listening "$OUT/cfg.log" 2>/dev/null && break
  sleep 0.25
done
grep -q "listening" "$OUT/cfg.log" || fail "the config file stopped the gateway from starting"
ok "the gateway starts with a config file present"

post() {
  curl -s -X POST -H 'content-type: application/json' \
    -d "$1" "http://127.0.0.1:$CFG_PORT/events"
}

# Nested-agent suppression: the whole event goes, not just the banner.
post '{"source":"x","kind":"approval","title":"nested","data":{"parent_session_id":"p"}}' > "$OUT/nested.txt"
grep -q '"suppressed":true' "$OUT/nested.txt" || fail "a nested-agent event was accepted with suppression on"
ok "suppress_nested_agent_push drops a nested agent's event"

post '{"source":"x","kind":"approval","title":"top"}' > /dev/null
TITLES="$(curl -s "http://127.0.0.1:$CFG_PORT/events")"
echo "$TITLES" | grep -q '"top"' || fail "suppression also dropped a top-level event"
echo "$TITLES" | grep -q '"nested"' && fail "the suppressed event reached the log anyway"
ok "suppression leaves top-level events alone"

# `data` has to survive the round trip. It was stored on the way in and not
# read back out, so everything an agent attached — which agent spawned this,
# which teammate sent it — arrived at the app as nothing, and the only code
# that reads the field runs on the request body, before the drop. Nothing
# downstream could have noticed.
post '{"source":"claude-code","kind":"notice","title":"teammate says hi","data":{"teammate":"scout"}}' > /dev/null
curl -s "http://127.0.0.1:$CFG_PORT/events" | python3 -I -c "
import json, sys
events = json.load(sys.stdin)['events']
match = [e for e in events if e.get('title') == 'teammate says hi']
assert match, 'the event did not come back at all'
assert match[0].get('data', {}).get('teammate') == 'scout', \
    'data was dropped between POST and GET: ' + json.dumps(match[0])
" || fail "an event's data does not survive POST -> GET"
ok "an event's data survives POST -> GET"

# The suppression must be off by default, or every existing install changes
# behaviour on upgrade.
DEFAULT_PORT=$((PORT + 4))
node "$CLI" --port "$DEFAULT_PORT" > "$OUT/default.log" 2>&1 &
DEFAULT_PID=$!
for _ in $(seq 1 20); do
  grep -q listening "$OUT/default.log" 2>/dev/null && break
  sleep 0.25
done
curl -s -X POST -H 'content-type: application/json' \
  -d '{"source":"x","kind":"notice","title":"nested","data":{"parent_session_id":"p"}}' \
  "http://127.0.0.1:$DEFAULT_PORT/events" > "$OUT/defaultnested.txt"
grep -q '"suppressed"' "$OUT/defaultnested.txt" && fail "suppression is on without being configured"
ok "nested suppression is off unless configured"

# scan_ports: an entry means the same thing alone or inside a list. The range
# in the array is the case that was silently dropped.
listen_on() {
  python3 -I -c "
import socket, time, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', int(sys.argv[1]))); s.listen(); time.sleep(12)
" "$1" &
}
listen_on 8005
listen_on 9999
sleep 1.5
PORTS="$(curl -s "http://127.0.0.1:$CFG_PORT/ports")"
echo "$PORTS" | python3 -I -c "
import json, sys
ports = json.load(sys.stdin)['ports']
assert 8005 in ports, 'a port inside the configured range was filtered out: ' + str(ports)
assert 9999 not in ports, 'a port outside scan_ports was not filtered'
" || fail "scan_ports did not filter as configured"
ok "scan_ports honours a range written inside a list"

kill "$CFG_PID" "$DEFAULT_PID" 2>/dev/null || true
pkill -f "bind(('127.0.0.1', 8005))" 2>/dev/null || true

# MARK: - diff, from a repo and outside one

run diff "$ROOT" > "$OUT/diff.txt" 2>&1 || fail "diff failed inside a repository"
grep -q "changed file(s)" "$OUT/diff.txt" || fail "diff did not summarise the repo"
ok "diff summarises a repository"

if run diff /tmp > "$OUT/nodiff.txt" 2>&1; then
  fail "diff succeeded outside a repository"
fi
grep -q "not a git repository" "$OUT/nodiff.txt" || fail "diff did not explain why it failed"
ok "diff refuses outside a repository, with the reason"

# A path that does not exist is the same class of mistake as a typo'd command,
# and must not be silently treated as one.
if run /no/such/directory > "$OUT/badpath.txt" 2>&1; then
  fail "a missing path exited zero"
fi
grep -q "no such directory" "$OUT/badpath.txt" || fail "a missing path gave the wrong error"
ok "a missing path is refused, not mistaken for a command"

printf '\nCLI_CHECK_PASS  (%d checks)\n' "$PASS"