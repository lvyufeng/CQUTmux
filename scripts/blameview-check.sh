#!/usr/bin/env bash
#
# Checks the blame screen's decisions: the request it sends, the rows it draws
# out of git's records, and the way it words a refusal.
#
# All three fail without an error appearing, which is why they are decided in
# `BlameModel.swift` rather than while drawing. `path` and `file` are opposite
# parameters, and a swapped pair is still a valid request — git is asked for a
# path that is not there relative to the directory it runs in and answers `no
# such path`, blaming the file for a mistake in the query. A row built from the
# raw fields shows an uncommitted line's all-zero hash as a commit and the
# moment of the blame as when the line was written. And every refusal arrives
# as "no lines", so a 403 drawn as a table reads as an empty file. Foundation-
# only, so this needs no simulator.
#
# Usage: scripts/blameview-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Features/Code/RevisionTree.swift" \
  "$ROOT/App/Features/Code/BlameModel.swift" \
  "$ROOT/scripts/blameview/main.swift" 2>&1 | grep -v "^ *$" || true

[[ -x "$OUT/check" ]] || { echo "BLAMEVIEW_BUILD_FAIL"; exit 1; }
"$OUT/check"