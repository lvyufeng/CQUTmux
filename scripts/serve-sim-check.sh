#!/usr/bin/env bash
#
# Checks serve-sim preview detection in `host/cqutmux-hook/serve-sim.mjs`.
#
# Usage: scripts/serve-sim-check.sh
#
# What is asserted
# ----------------
# Moshi's documentation (https://getmoshi.app/docs/simulator-preview) says a
# serve-sim preview is detected automatically from three triggers — "The process
# or its command line contains `serve-sim`", "The state file serve-sim writes
# under `$TMPDIR/serve-sim/` lists the port", and "The page carries serve-sim's
# preview marker" — and that it "shows up as **Simulator Preview** with the
# device name when the state file is available" and "never appears twice in the
# web server list."
#
# Each failure below is quiet. A trigger that does not fire leaves the preview
# showing as an anonymous port; a trigger that over-fires puts a wrong
# "Simulator Preview" label on an unrelated server; and a duplicate row is a
# second entry for one preview. None is visible without checking, so the three
# triggers are driven directly — including a state directory the checking machine
# does not have, since `serve-sim.mjs` is pure and takes `$TMPDIR` as a
# parameter — and the no-duplicate rule is asserted as a port count.
#
# Mutation-testing this check
# ---------------------------
# Each group was checked by breaking the module and watching exactly the
# matching assertions go red:
#   - match `serve-sim` as a bare substring   -> the `serve-simulator` /
#     `restart-serve-sim-old` near-miss assertions fail
#   - drop the state-file port as a trigger   -> the state-file assertions fail
#   - drop the marker header/body test        -> the marker assertions fail
#   - append the preview instead of annotating -> the "appears exactly once"
#     assertion fails
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> checking the serve-sim preview rules"
node scripts/serve-sim/main.mjs