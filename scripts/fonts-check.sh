#!/usr/bin/env bash
#
# Checks importing a font the user brought: what is accepted, what is copied,
# and what the stored name actually resolves to.
#
# Every rule here fails in a way that looks like something else. A rejected
# extension leaves a font rendering as the system's, which reads as "the import
# silently did nothing". A copy that does not happen works today and vanishes
# after the next launch. A name taken from the filename rather than from the
# font makes the later `UIFont(name:)` fail for reasons nobody can see.
#
# The store reads fonts through Core Text and never through UIKit, so this needs
# no simulator.
#
# Usage: scripts/fonts-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Features/Settings/CustomFontStore.swift" \
  "$ROOT/scripts/fonts/main.swift"

"$OUT/check"
