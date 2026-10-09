#!/usr/bin/env bash
#
# Checks the watch usage payload: which window a ring highlights, which number a
# complication would show, and the field names that make the phone and the watch
# able to read each other's encoding.
#
# Both derived values fail invisibly. Picking the wrong window, or the mean of
# the accounts instead of the peak, produces a plausible percentage that is not
# the one a rate-limit display exists to show — and the user would only find out
# by being cut off. The field names matter because the two targets compile this
# file separately; a rename that only one of them follows is a silent no-data
# state on the wrist.
#
# `WatchPayload.swift` is shared with the watch target and imports Foundation
# only, so this needs no simulator.
#
# Usage: scripts/watch-usage-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Shared/WatchPayload.swift" \
  "$ROOT/scripts/watch-usage/main.swift"

"$OUT/check"