#!/usr/bin/env bash
#
# Checks the multiplexer diagnostics in `host/cqutmux-hook/doctor-mux.mjs`.
#
# Usage: scripts/mux-doctor-check.sh
#
# What is asserted
# ----------------
# `cqutmux doctor` reproduces the session picker's preflight — an `sh -lc` with
# a fixed PATH prepended — and compares what the picker would resolve against
# what the daemon resolves. When the two disagree the app shows nothing: the
# session tab simply never appears, and nothing anywhere says why. So the rules
# that decide "disagree" have to be checked without a host that disagrees.
#
# `doctor-mux.mjs` is pure (it builds a script and reads a string, and spawns
# nothing), which is what lets the assertions run anywhere. They cover:
#
# 1. The preflight PATH is prepended in the picker's order, not replaced.
# 2. The duplicate probe is one that actually runs — the documented
#    `command -v -a` does not exist, and a probe built on it answers nothing,
#    which reads as "not installed".
# 3. Version strings normalise, so `tmux 3.5a` and `3.5a` are one build.
# 4. Three disagreements are told apart (daemon cannot find it / duplicate /
#    version split), because their fixes differ, and none of them is "absent",
#    which is not a problem at all.
#
# The assertions live in `scripts/mux-doctor/main.mjs` rather than inline here:
# the values under test are PATH strings and shell pipelines, and getting those
# through bash's escaping without a mismatch is more error-prone than reading
# them from a file.
#
# Mutation-testing this check
# ---------------------------
# Each assertion pair was checked by breaking the module and watching exactly
# one thing go red:
#   - drop `which -a` from the probe        -> duplicate detection is gone
#   - prepend `command -v -a` back          -> the probe never enumerates
#   - compare versions raw                  -> a healthy host warns forever
#   - treat `absent` as a problem           -> doctor fails on a bare host
#   - treat two identical paths as distinct -> the symlink case warns
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> checking the multiplexer diagnostics"
node scripts/mux-doctor/main.mjs
echo "MUX_DOCTOR_OK"