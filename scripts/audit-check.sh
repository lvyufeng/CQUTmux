#!/usr/bin/env bash
#
# Checks the parity audit's own numbers against the things they describe: that
# the counters in docs/parity-audit.json are the tally of its entries, that the
# table in the prose agrees with them, that every check script it cites still
# exists, and that every count it quotes is the count that check prints.
#
# The file exists to be trusted by someone who cannot re-run the work, and it has
# been wrong in ways nothing caught: a hand-maintained table five closures behind
# the counters beside it, a `verification` field describing the opposite of its
# `evidence`, and counts quoted from runs long past. Those are all numbers, which
# is to say they are all checkable.
#
# `--observed <file>` takes one `<script> <count>` line per check, which is how
# `scripts/checks.sh` passes what this run measured. Without it the structural
# half still runs and the quoted counts are reported as unverified rather than
# assumed correct.
#
# Usage: scripts/audit-check.sh [--observed <file>]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node --check "$ROOT/scripts/audit/main.mjs"
node "$ROOT/scripts/audit/main.mjs" "$@"
