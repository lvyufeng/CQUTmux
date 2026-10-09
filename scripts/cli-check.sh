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