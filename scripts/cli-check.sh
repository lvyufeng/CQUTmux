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

# MARK: - Easy Pair
#
# `pair` now sets the host up rather than only describing it, and the thing that
# has to hold is across two languages and two machines: the host writes the link
# in JavaScript, the app reads it in Swift, and there is no error channel
# between them. So what it printed is read back with the app's own parser
# (`scripts/pair-parse.sh` links the file the app ships) rather than with a
# second reading written inside this check, which would only prove the host
# agrees with itself. It runs against a throwaway HOME so no real key or
# `authorized_keys` is touched.

PAIR_HOME="$OUT/pairhome"
mkdir -p "$PAIR_HOME/.ssh"
chmod 700 "$PAIR_HOME/.ssh"

HOME="$PAIR_HOME" run pair --port 2222 --token 'tok&en' --host 10.1.2.3 --user 'the user' \
  > "$OUT/pair.txt" 2>&1 || fail "pair exited non-zero"

[ -f "$PAIR_HOME/.ssh/cqutmux_ed25519" ] || fail "pair did not generate a key"
# The public key's own body, not the filename: what has to be in the file is the
# key, and a check for the path would pass with any line mentioning it.
PUB_BODY="$(awk '{print $2}' "$PAIR_HOME/.ssh/cqutmux_ed25519.pub")"
grep -q "$PUB_BODY" "$PAIR_HOME/.ssh/authorized_keys" \
  || fail "pair did not authorise the key it generated"
# The private key must never be written where anything else reads it.
grep -q "PRIVATE KEY" "$PAIR_HOME/.ssh/authorized_keys" \
  && fail "the private key was written into authorized_keys"
ok "pair generates a key and authorises only its public half"

# The link is the last line that starts with the scheme; the QR drawing and the
# prose around it must not be mistaken for it.
LINK="$(grep -m1 '^cqutmux://pair' "$OUT/pair.txt")"
[ -n "$LINK" ] || fail "pair printed no link"
ok "pair prints the link itself, not only a QR code"

# The QR code is drawn above it. If the drawing were empty or the link were left
# out of it, a camera would see nothing while the command reported success.
QR_ROWS="$(grep -c '█' "$OUT/pair.txt")"
[ "$QR_ROWS" -ge 20 ] || fail "pair did not draw a QR code ($QR_ROWS rows)"
ok "pair draws a QR code"

PARSED="$(scripts/pair-parse.sh link "$LINK")" || fail "the app's parser rejected the link pair printed"
python3 -I -c "
import json, sys
p = json.loads('''$PARSED''')
assert p['host'] == '10.1.2.3', 'host: ' + json.dumps(p)
assert p['port'] == 2222, 'port: ' + json.dumps(p)
assert p['username'] == 'the user', 'username: ' + json.dumps(p)
assert p['token'] == 'tok&en', 'token: ' + json.dumps(p)
assert p['keyBytes'] == 32, 'the key did not survive as a 32-byte seed: ' + json.dumps(p)
assert p['version'] == 1, 'version: ' + json.dumps(p)
" || fail "the app read the link as different fields from what the host printed"
ok "the app reads back host, port, user and token from what pair printed"

# The key travels in the fragment, which is the part a server or a chat preview
# never sees. A link with the key in the query would leak it into every log it
# passes.
case "$LINK" in
  *'#key='*) ;;
  *) fail "the key is not in the fragment: $LINK" ;;
esac
case "${LINK%%#*}" in
  *key=*) fail "the key is in the query string, where it does not stay private" ;;
esac
ok "the private key travels in the fragment, never the query"

# A second run must reuse the key rather than replace it, or every pairing
# invalidates the phones already paired.
KEY_BEFORE="$(shasum "$PAIR_HOME/.ssh/cqutmux_ed25519.pub" | cut -d' ' -f1)"
HOME="$PAIR_HOME" run pair --host 10.1.2.3 > /dev/null 2>&1 || fail "a second pair exited non-zero"
KEY_AFTER="$(shasum "$PAIR_HOME/.ssh/cqutmux_ed25519.pub" | cut -d' ' -f1)"
[ "$KEY_BEFORE" = "$KEY_AFTER" ] || fail "pairing twice replaced the key, invalidating the phone already paired"
ok "pairing again reuses the key"

# The path the phone should dial, learned from what the host actually wrote.
HOME="$PAIR_HOME" run pair --host 10.1.2.3 --user u > "$OUT/pair2.txt" 2>&1
LINK2="$(grep -m1 '^cqutmux://pair' "$OUT/pair2.txt")"
scripts/pair-parse.sh link "$LINK2" > "$OUT/link2.json" || fail "the app rejected a link with no token"
python3 -I -c "
import json
p = json.load(open('$OUT/link2.json'))
assert 'token' not in p, 'a token appeared in a link made without one: ' + json.dumps(p)
assert p['keyBytes'] == 32, 'the key was lost when no token was set'
" || fail "a host with no gateway token produced a wrong link"
ok "a link without a token still pairs, key included"

# MARK: - The round trip through the app's writer
#
# `Pairing.string` is the app's half of the format. The host has to read links
# the app writes as well, because a host that can only write would break the day
# the app gains a "share this host" button.

LINK3="$(echo '{"host":"10.9.9.9","port":22,"username":"someone","name":"a box"}' | scripts/pair-parse.sh build)" \
  || fail "the app could not write a link"
scripts/pair-parse.sh link "$LINK3" > "$OUT/link3.json" || fail "the app rejected its own link"
python3 -I -c "
import json
p = json.load(open('$OUT/link3.json'))
assert p['host'] == '10.9.9.9' and p['port'] == 22 and p['username'] == 'someone', json.dumps(p)
assert p['name'] == 'a box', 'a name with a space did not survive: ' + json.dumps(p)
" || fail "a link the app wrote did not read back the same"
ok "a link the app writes reads back the same through the app's parser"

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

# Against a port this script has proved is free, not the default. With no
# --port, doctor probes 24543, which may be a user's own gateway, a leftover
# from an earlier run, or a socket in TIME_WAIT -- so the result depends on
# whatever else is on the machine, and one run of this check did fail that way.
# An explicit dead port makes the gateway line a fast, predictable FAIL.
run doctor --port "$DEAD_PORT" > "$OUT/doctor.txt" 2>&1 || true   # non-zero is expected without tmux
grep -qE "^(ok|FAIL)  (tmux|git|ssh)" "$OUT/doctor.txt" || fail "doctor checked none of its tools"
grep -qE "^(ok|FAIL)  gateway" "$OUT/doctor.txt" || fail "doctor did not check the gateway"
# The multiplexer section is the one part of doctor that reports on a thing that
# is *not* an error to be missing -- so it has to say so rather than print
# nothing, and it has to appear at all. Both are silent failures: a section that
# never renders and a section that renders an empty list look the same as a host
# with no multiplexer, which is a normal host.
grep -q "^Multiplexers$" "$OUT/doctor.txt" || fail "doctor has no Multiplexers section"
grep -qE "^  (ok|warn) " "$OUT/doctor.txt" || fail "the Multiplexers section listed nothing at all"
# A crashed doctor also produces no matching line, and "it died" and "it
# disagreed" want different investigations -- so require the report to look
# like a report.
[ "$(wc -l < "$OUT/doctor.txt")" -ge 5 ] \
  || fail "doctor produced no report (see $OUT/doctor.txt)"
ok "doctor checks the tools, the gateway, and the multiplexers"

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

# A question with choices is answered by choosing one, and the choice has to
# come back on the event — otherwise the app resolves it locally and the agent
# never learns which option the user picked, which looks identical to a working
# screen until the agent acts on the wrong thing.
post '{"source":"claude-code","kind":"approval","title":"deploy where?","data":{"options":[{"label":"staging","value":"staging"},{"label":"production","value":"prod"}]}}' > "$OUT/q.json"
QID="$(python3 -I -c "import json;print(json.load(open('$OUT/q.json'))['id'])")"
curl -s -X POST -H 'content-type: application/json' -d '{"decision":"allow","answer":"prod"}' \
  "http://127.0.0.1:$CFG_PORT/approve/$QID" > "$OUT/qres.json"
python3 -I -c "
import json
e = json.load(open('$OUT/qres.json'))
assert e['decision'] == 'allow', 'the decision was not recorded: ' + json.dumps(e)
assert e.get('answer') == 'prod', 'the chosen option was dropped: ' + json.dumps(e)
" || fail "answering a question did not record the choice"
ok "a question records which option was chosen"

# An option value is agent-supplied text. One containing a quote must survive
# the round trip, which is what the app's encoded body is for.
post '{"source":"x","kind":"approval","title":"quoted","data":{"options":[{"label":"a","value":"say \"hi\""}]}}' > "$OUT/q2.json"
Q2ID="$(python3 -I -c "import json;print(json.load(open('$OUT/q2.json'))['id'])")"
printf '%s' '{"decision":"allow","answer":"say \"hi\""}' > "$OUT/qbody.json"
curl -s -X POST -H 'content-type: application/json' --data-binary @"$OUT/qbody.json" \
  "http://127.0.0.1:$CFG_PORT/approve/$Q2ID" | python3 -I -c "
import json,sys
e = json.load(sys.stdin)
assert e.get('answer') == 'say \"hi\"', 'a quoted option value did not survive: ' + json.dumps(e)
" || fail "an option value containing a quote did not survive"
ok "an option value containing a quote survives the round trip"

# The notice the gateway emits beside the decision is what tells the *other*
# devices. The poll asks for `id > lastId`, so an approval a device already
# holds is never re-sent with its decision on it: an approval answered on the
# watch left the row on the phone in "Needs you" forever. The decision therefore
# has to ride on the notice, along with the session so the row it belongs to can
# be found.
post '{"source":"claude-code","kind":"approval","title":"ship it?","data":{"session":"sess-zz"}}' > "$OUT/r.json"
RID="$(python3 -I -c "import json;print(json.load(open('$OUT/r.json'))['id'])")"
curl -s -X POST -H 'content-type: application/json' -d '{"decision":"deny"}' \
  "http://127.0.0.1:$CFG_PORT/approve/$RID" > /dev/null
curl -s "http://127.0.0.1:$CFG_PORT/events" | python3 -I -c "
import json, sys
events = json.load(sys.stdin)['events']
notice = [e for e in events if e.get('source') == 'app' and e.get('data', {}).get('for') == int('$RID')]
assert notice, 'resolving an approval emitted no notice for the other devices'
data = notice[0]['data']
assert data.get('decision') == 'deny', \
    'the notice does not say how it was decided: ' + json.dumps(data)
assert data.get('session') == 'sess-zz', \
    'the notice does not say which session it belongs to: ' + json.dumps(data)
" || fail "the resolution notice does not carry what other devices need"
ok "the resolution notice carries the decision and the session"


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

# `cqutmux diff` is a *viewer server*, not a report: it prints a URL and holds
# the port until it is stopped. The check has to drive it as one — run it in the
# background, read the URL it prints, and fetch the page.
#
# Running it in the foreground, as this did until 2026-10-11, waits forever on a
# server that is working exactly as intended, and greps its stdout for a summary
# it stopped printing when the viewer landed (the summary is in the HTML now).
# This check passed when it was written because `diff` printed a summary and
# returned; when it became a server the check did not fail, it *hung* — the same
# "a client that opens a connection never exits" shape recorded against
# `scripts/pushsend-check.sh`, and the reason that note says a socket-owning
# check has to be run with a timeout the first time.
DIFF_PORT=$((PORT + 5))
node "$CLI" diff "$ROOT" --no-open --port "$DIFF_PORT" > "$OUT/diff.txt" 2>&1 &
DIFF_PID=$!
for _ in $(seq 1 20); do
  grep -q "serving" "$OUT/diff.txt" 2>/dev/null && break
  sleep 0.25
done
grep -q "serving" "$OUT/diff.txt" || fail "diff did not start its viewer (see $OUT/diff.txt)"
ok "diff starts a viewer and prints where it is"

DIFF_HTML="$(curl -s -m 5 "http://127.0.0.1:$DIFF_PORT/")"
echo "$DIFF_HTML" | grep -q "changed file(s)" || fail "the diff page does not summarise the repo"
ok "the diff page summarises the repository"

# A server a check starts has to be *stoppable*, or the check leaks a process
# and a port. Asserting the signal handler rather than merely killing it is the
# point: a diff that ignores SIGTERM is a diff nobody can stop.
kill "$DIFF_PID" 2>/dev/null || true
for _ in $(seq 1 20); do
  kill -0 "$DIFF_PID" 2>/dev/null || break
  sleep 0.25
done
kill -0 "$DIFF_PID" 2>/dev/null && fail "diff did not stop on SIGTERM"
ok "diff stops when signalled, rather than holding the port"

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

# MARK: - version, set, uninstall

# The gateway version and the app version have to be the same number — they
# are released together, and a `cqutmux version` that disagrees with what the
# app's Support screen shows is worse than not having the command.
APP_VERSION="$(grep -m1 'MARKETING_VERSION' "$ROOT/project.yml" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
run version > "$OUT/version.txt" 2>&1 || fail "version failed"
grep -q "$APP_VERSION" "$OUT/version.txt" \
  || fail "version does not match project.yml ($APP_VERSION): $(cat "$OUT/version.txt")"
ok "version matches the app's MARKETING_VERSION"

# `set` writes the config file the reader parses, and `on`/`off` mean the
# booleans — a quoted "off" would read back as a truthy string and turn the
# setting *on*, which is the failure this check exists for.
CFG="$(mktemp -d)/config.toml"
CQUTMUX_CONFIG="$CFG" run set usage-collection off > /dev/null || fail "set failed"
grep -q 'usage_collection = false' "$CFG" || fail "set did not write a boolean: $(cat "$CFG")"
CQUTMUX_CONFIG="$CFG" run set usage-collection > "$OUT/get.txt" 2>&1
grep -q 'false' "$OUT/get.txt" || fail "set did not read back what it wrote"
ok "set writes a value the config reader reads back as a boolean"

# An unknown key has to be refused rather than written and ignored: a typo that
# silently does nothing is exactly what this command exists to prevent.
if CQUTMUX_CONFIG="$CFG" run set not-a-setting 1 > "$OUT/badset.txt" 2>&1; then
  fail "set accepted an unknown key"
fi
grep -q 'unknown setting' "$OUT/badset.txt" || fail "set gave the wrong error for an unknown key"
ok "set refuses an unknown key"

# A repeated write must not grow the file a blank line at a time.
BEFORE="$(wc -c < "$CFG")"
CQUTMUX_CONFIG="$CFG" run set usage-collection off > /dev/null
CQUTMUX_CONFIG="$CFG" run set usage-collection off > /dev/null
AFTER="$(wc -c < "$CFG")"
[[ "$BEFORE" == "$AFTER" ]] || fail "repeated set grew the config file ($BEFORE -> $AFTER)"
ok "setting the same value twice leaves the file unchanged"

# `usage` needs a gateway — it says so rather than printing an empty board.
if CQUT_CLI_UNUSED=1 run usage --port 24997 > "$OUT/usage.txt" 2>&1; then
  fail "usage succeeded with no gateway"
fi
grep -q 'no gateway' "$OUT/usage.txt" || fail "usage blamed the wrong thing"
ok "usage explains that it needs a running gateway"

printf '\nCLI_CHECK_PASS  (%d checks)\n' "$PASS"