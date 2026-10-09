#!/usr/bin/env bash
#
# Checks the transcription history: the cap, the de-duplication, what survives a
# relaunch, and — most of all — what is not in it.
#
# This is a list of things the user said out loud, so its contents are part of
# the contract rather than an implementation detail. The store is fed from the
# dictation callback and never from the terminal's input path, which is what
# keeps a typed password out; these checks pin the rules that keep the list
# useful and bounded, and the ones that make a bad stored blob degrade to empty
# rather than to a crash.
#
# The file imports Foundation only, so this needs no simulator.
#
# Usage: scripts/history-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Features/Voice/TranscriptionHistory.swift" \
  "$ROOT/scripts/history/main.swift"

"$OUT/check"