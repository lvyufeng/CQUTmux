#!/usr/bin/env bash
#
# Checks the host status dot: the five states the probe decides between, and
# that each carries the fix that actually resolves it.
#
# Usage: scripts/gateway-status-check.sh
#
# What is asserted
# ----------------
# 1. `GatewayStatus.interpret` maps the probe's `key=value` lines to the right
#    state for every case — including the two that are easy to get backwards:
#    a gateway answering on the *default* port while the host is set elsewhere
#    is "wrong port", not "not running"; and a 404 on the configured port is
#    "update", not "running", because an older gateway does not know routes this
#    app uses.
# 2. Every non-running state offers a `fix`, and the two quiet states do not
#    invent one — a state that says something is wrong without saying what to do
#    is the failure this screen exists to avoid, and one that offers a fix for a
#    working gateway sends the user to break it.
# 3. The probe script prints the keys the interpreter reads, so the two halves
#    cannot drift apart.
#
# `GatewayStatus.swift` holds the pure half and imports only Foundation, so it
# is run here directly through the Swift interpreter — no host, no simulator.
# That separation is written into the code for exactly this reason: the five
# states are where a mistake shows the user the *wrong fix*.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SWIFT_FILE="App/Features/Hosts/GatewayStatus.swift"

# The pure half must stay pure, or the check silently starts needing a host.
if grep -qE '^import ' "$SWIFT_FILE" | grep -qv '^import Foundation$'; then
  echo "FAIL: $SWIFT_FILE imports something beyond Foundation:"
  grep -E '^import ' "$SWIFT_FILE" | grep -v '^import Foundation$'
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> checking the five states and their fixes"
cat "$SWIFT_FILE" > "$WORK/main.swift"
cat >> "$WORK/main.swift" <<'SWIFT'

func check(_ condition: Bool, _ message: String) {
    if !condition {
        print("FAIL: \(message)")
        exit(1)
    }
}

let defaultPort = GatewayStatus.defaultPort

/// Builds the probe's stdout from facts, so the interpreter is checked against
/// the same `key=value` shape the shell script produces.
func interpret(_ facts: [(String, String)], configured: Int = GatewayStatus.defaultPort) -> GatewayState {
    let text = facts.map { "\($0.0)=\($0.1)" }.joined(separator: "\n")
    return GatewayStatus.interpret(text, configuredPort: configured, exitCode: 0)
}

// 1. Running: the configured port answers 200.
let running = interpret([("tool", "/usr/local/bin/cqutmux"), ("version", "1.4.0"), ("port_24543", "200")])
check(running.isUp, "a 200 on the configured port is not running: \(running)")
check(running.label == "Running", "wrong label for running: \(running.label)")

// 2. Update: something answers, but not with a route this app knows. A 404 on
//    the health route is what a gateway from before that route looks like.
let old = interpret([("tool", "/usr/local/bin/cqutmux"), ("version", "0.9.0"), ("port_24543", "404")])
if case .update = old {} else {
    print("FAIL: a 404 on the configured port was not read as an update: \(old)")
    exit(1)
}

// 3. Wrong port — the case that is easy to get backwards. Nothing on the port
//    the host is set to, but a gateway on the *default* one: the tool is
//    running, the app is just looking where it is not.
let wrong = interpret(
    [("tool", "/usr/local/bin/cqutmux"), ("version", "1.4.0"), ("port_24611", "000"), ("port_24543", "200")],
    configured: 24611
)
if case .wrongPort(let found) = wrong {
    check(found == defaultPort, "wrong-port reported \(found), not \(defaultPort)")
} else {
    print("FAIL: a gateway on the default port was not read as wrong-port: \(wrong)")
    exit(1)
}

// 4. Not running: the tool is there, nothing answers anywhere.
let down = interpret([("tool", "/usr/local/bin/cqutmux"), ("version", "1.4.0"), ("port_24543", "000")])
if case .notRunning = down {} else {
    print("FAIL: an installed tool with no listener was not read as not-running: \(down)")
    exit(1)
}

// 5. Not installed: no tool, no listener. Reported distinctly, because the fix
//    is a different command entirely.
let missing = interpret([("tool", "none"), ("version", "none"), ("port_24543", "000")])
if case .notInstalled = missing {} else {
    print("FAIL: a host with no tool was not read as not-installed: \(missing)")
    exit(1)
}

// A host whose port *is* the default must not be told it has a port problem
// when nothing answers: that reading would send the user to change a port that
// is already right. This is the one case where the two failure states could be
// confused for each other.
if case .notRunning = down {} else {
    print("FAIL: a host on the default port with nothing running was read as \(down)")
    exit(1)
}

// A gateway answering a *non*-404 status on the configured port is running even
// if that status is not 200: a 401 means it is there and wants the token, which
// is a different problem from a missing route.
let unauthorized = interpret([("tool", "cqutmux"), ("version", "1.4.0"), ("port_24543", "401")])
check(unauthorized.isUp, "a 401 on the configured port should still read as running: \(unauthorized)")

// Every state that reports trouble must say what to do about it, and the two
// quiet states must not invent a fix.
for state: GatewayState in [.update(version: nil), .update(version: "0.9"), .wrongPort(found: 1), .notRunning, .notInstalled] {
    check(state.fix != nil, "\(state.label) has no fix")
    check(!state.detail.isEmpty, "\(state.label) has no detail")
}
check(GatewayState.unknown.fix == nil, "unknown should offer no fix")
check(GatewayState.running(version: "1.0", pending: 0).fix == nil, "running should offer no fix")

// A port that reported *anything* other than a clean status must not be read
// as answering. This is the shape a doubled `000` takes — curl prints `000`
// itself for a refused connection, and an extra fallback appended another,
// so every dead port read as live and every host showed a green dot. The value
// here is exactly what that bug produced.
let doubled = interpret([("tool", "none"), ("port_24543", "000000")])
if case .notInstalled = doubled {} else {
    print("FAIL: a garbled port value read as answering: \(doubled)")
    exit(1)
}
// And the same for the common near-miss spellings, which must all be "dead".
for value in ["000", "", "0", "n/a", "-1"] {
    let state = interpret([("tool", "cqutmux"), ("port_24543", value)])
    if case .notRunning = state {} else {
        print("FAIL: port value \(value.debugDescription) read as answering: \(state)")
        exit(1)
    }
}

// The probe script prints the keys the interpreter reads. Checked by reading
// the script's `printf` keys out of its own source, since the two live in one
// file and a rename in one place must not silently strand the other.
let script = GatewayStatus.probeScript(ports: [24543, 24611])
for key in ["tool", "version", "port_24543", "port_24611"] {
    check(script.contains("printf '\(key)=%s"), "probeScript does not print \(key)")
}

print("PASS: all five states, their fixes, and the probe keys line up")
SWIFT

swift "$WORK/main.swift"
echo "GATEWAY_STATUS_PASS"