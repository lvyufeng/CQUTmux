#!/usr/bin/env bash
#
# Checks the listener-probe rules: how lsof/ss output is read, what an address's
# scope means, and which framework name a command or header earns.
#
# The failure this guards against is a wrong name that reads exactly like a
# right one — the phone shows "Vite" and the user opens it expecting their dev
# server. `listeners.mjs` is plain node with no gateway, so this needs no host.
#
# Usage: scripts/listeners-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node --check "$ROOT/host/cqutmux-hook/listeners.mjs"
node "$ROOT/scripts/listeners/main.mjs"
