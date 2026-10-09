#!/usr/bin/env bash
#
# Checks the host's QR encoder, which is a second implementation of the
# algorithm the app already has.
#
# Two encoders of one format is the arrangement where a bug hides: each half
# looks right alone, and the phone silently binds to a host the other end never
# meant. So the JS is judged by the same reference matrices as the Swift, read
# out of `scripts/qr/main.swift` so that both are measured against the
# independent encoder that produced them rather than against each other.
#
# Node-only, so this needs no simulator and no compiler.
#
# Usage: scripts/qr-js-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node "$ROOT/scripts/qr-js/main.mjs" "$ROOT/scripts/qr/main.swift"