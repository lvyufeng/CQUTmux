#!/usr/bin/env bash
#
# Checks which sources the Add-attachment sheet offers.
#
# The rule that fails silently is *which rows appear*: a Clipboard row with
# nothing on the clipboard opens onto "No image on the clipboard" and reads as a
# broken button, and a Camera row on a device without a camera does the same.
# A screenshot shows the rows that were drawn, never the one that should have
# been, so the decision lives in a Foundation-only enum and is driven here.
#
# Usage: scripts/attachment-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The file has to stay Foundation-only for this to compile without UIKit.
if grep -E '^import ' App/Features/Terminal/AttachmentSources.swift \
    | grep -qv '^import Foundation$'; then
  echo "FAIL: AttachmentSources.swift imports beyond Foundation:"
  grep -E '^import ' App/Features/Terminal/AttachmentSources.swift
  exit 1
fi

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  App/Features/Terminal/AttachmentSources.swift \
  scripts/attachment/main.swift 2>&1 | grep -v "^ *$" || true

[[ -x "$OUT/check" ]] || { echo "ATTACHMENT_BUILD_FAIL"; exit 1; }
"$OUT/check"