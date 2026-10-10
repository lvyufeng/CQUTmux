#!/usr/bin/env bash
#
# Checks the diff-viewer page: that repository text cannot become markup, and
# that a line's mark is not mistaken for its content.
#
# The failure this guards against is the quiet one: a diff page that renders a
# `<script>` in a source file as a script, or that shows `+foo` where the file
# says `foo`. `diffpage.mjs` is plain node, so this needs no gateway and no
# browser.
#
# Usage: scripts/diffpage-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node --check "$ROOT/host/cqutmux-hook/diffpage.mjs"
node "$ROOT/scripts/diffpage/main.mjs"
