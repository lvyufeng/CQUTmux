#!/usr/bin/env bash
#
# Checks the History tab's commit annotations: the diffstat each row shows, and
# the merge that has none.
#
# The line this parses is git's own `--shortstat`, which is git's to change, so
# the fixture is a real repository driven through real git rather than a typed
# copy of its output. `revision.mjs` is plain node with no gateway behind it.
#
# Usage: scripts/log-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node --check "$ROOT/host/cqutmux-hook/revision.mjs"
node "$ROOT/scripts/log/main.mjs"
