#!/usr/bin/env bash
#
# Exercises the Cloud dictation engine's two silent-failure surfaces: the WAV
# container it posts and the parser that reads the answer back.
#
# Neither fails loudly in the app. A malformed header still makes a valid HTTP
# body, and a response read from the wrong field is still a string — the only
# place either shows up is the transcript, which no automated check in the app
# looks at. So this reads the bytes.
#
# `CloudTranscription` has no AVFoundation or SwiftUI dependency precisely so
# this needs no simulator.
#
# Usage: scripts/cloud-dictation/run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Features/Voice/CloudTranscription.swift" \
  "$ROOT/scripts/cloud-dictation/main.swift"

"$OUT/check"