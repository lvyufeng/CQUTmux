#!/usr/bin/env bash
#
# Checks the terminal-context probe: which multiplexer a shell reports, the
# innermost one when they nest, and the JSON it prints.
#
# The probe is run by prompts and status lines that trust it silently, so a
# wrong pane is not an error — it is valid JSON naming the wrong place.
# `context.mjs` is plain node, so this needs no gateway.
#
# Usage: scripts/context-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node --check "$ROOT/host/cqutmux-hook/context.mjs"
node "$ROOT/scripts/context/main.mjs"
