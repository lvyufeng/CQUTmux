#!/usr/bin/env bash
#
# Checks the QR encoder against reference matrices and reads the payload back
# out with an independent decoder.
#
# A QR code fails in the worst way for a pairing flow: a code that scans to
# *something* is far more common than one that does not scan at all, and a
# payload one bit wrong binds the app to a different host with no error shown
# anywhere. So this compares whole matrices module by module rather than
# checking that the shape looks right.
#
# `QRCode.swift` is Foundation-only, so this needs no simulator.
#
# Usage: scripts/qr-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Shared/QRCode.swift" \
  "$ROOT/scripts/qr/main.swift" 2>&1 | grep -vE "warning:" || true

[[ -x "$OUT/check" ]] || { echo "QR_BUILD_FAIL"; exit 1; }
"$OUT/check"
