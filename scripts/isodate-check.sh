#!/usr/bin/env bash
#
# Checks the timestamp parser against what the gateway actually writes.
#
# This exists because the bug it covers was invisible. A default-configured
# `ISO8601DateFormatter` rejects the millisecond timestamps `toISOString()`
# produces, returning nil rather than throwing, and a nil optional date renders
# as a blank — so every relative time in the app was missing its value and it
# read as a layout quirk rather than a parse failure. Nothing crashed, nothing
# logged, and the only symptom was an absence.
#
# The check is written from the producer's side: it takes the exact shapes the
# gateway and agents emit and asserts they parse. A future change to the writer
# that breaks the reader should fail here.
#
# Usage: scripts/isodate-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# `ISODate` is Foundation-only, so this needs no simulator and no packages.
swiftc -O -o "$OUT/check" \
  "$ROOT/App/Shared/ISODate.swift" \
  "$ROOT/scripts/isodate/main.swift"

"$OUT/check"