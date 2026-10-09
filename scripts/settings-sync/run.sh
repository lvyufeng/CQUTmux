#!/usr/bin/env bash
#
# Exercises the sync decision and merge rules.
#
# These are the only part of sync that is genuinely hard to get right and the
# only part that cannot be reproduced on demand: a conflict needs two devices
# that both moved since the last exchange, and no manual test can arrange that.
# The CloudKit transport underneath is a few lines of API; the questions worth
# checking are which side wins, what a union does, and — most of all — that the
# payload cannot carry a secret.
#
# `SettingsSync` has no CloudKit dependency precisely so this needs neither a
# simulator nor an iCloud account.
#
# Usage: scripts/settings-sync/run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# Only the types the payload is made of. `SpeechSettings` is deliberately not
# here: its `Dictation` class owns the audio engines, so compiling it standalone
# would mean stubbing the SwiftPM speech products for no gain — the merge rules
# do not touch it.
swiftc -O -o "$OUT/check" \
  "$ROOT/App/Features/Hosts/Host.swift" \
  "$ROOT/App/Features/Settings/TerminalTheme.swift" \
  "$ROOT/App/Features/Settings/SettingsSync.swift" \
  "$ROOT/scripts/settings-sync/main.swift"

"$OUT/check"