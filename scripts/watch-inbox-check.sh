#!/usr/bin/env bash
#
# Checks the watch inbox grouping: which items land under which project heading,
# and whether a heading is drawn at all.
#
# Grouping fails invisibly in two directions. An item whose hook reported no
# working directory must still be shown — it is a waiting approval, not an empty
# cell — and must not become one group per item. And a single project must not
# be given a header: a lone title over everything is chrome, not information.
# Neither shows up in a screenshot of a working wrist; both show up here.
#
# `WatchPayload.swift` is shared with the watch target and imports Foundation
# only, so this needs no simulator.
#
# Usage: scripts/watch-inbox-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Shared/WatchPayload.swift" \
  "$ROOT/scripts/watch-inbox/main.swift"

"$OUT/check"
