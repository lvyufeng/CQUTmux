#!/usr/bin/env bash
#
# Checks the service-file builder in `host/cqutmux-hook/service.mjs`.
#
# Usage: scripts/service-check.sh
#
# What is asserted
# ----------------
# `cqutmux service install` writes a launchd plist or a systemd user unit so the
# gateway survives the terminal that started it. The file's *content* is what is
# easy to get wrong — a missing `RunAtLoad`, an unquoted path with a space, a
# token whose `&` is not escaped — and every one of those produces a service
# that installs, reports success, and never runs. That is the failure mode the
# feature exists to remove, arriving through the feature itself.
#
# `service.mjs` is pure (it builds a string and touches nothing), so the content
# can be asserted on a machine that runs neither supervisor. On a macOS box the
# systemd branch never executes; here it does.
#
# The assertions live in `scripts/service/main.mjs` rather than inline: the
# values under test are XML and unit text, and getting those through bash's
# escaping without a mismatch is more error-prone than reading them from a file.
#
# Mutation-testing this check
# ---------------------------
# Each group was checked by breaking the module and watching exactly one thing
# go red:
#   - drop `RunAtLoad`                     -> the login-start assertion fails
#   - stop quoting systemd args            -> the path-with-space assertion fails
#   - escape `&` after `<`/`>`             -> the double-escape assertion fails
#   - make the unit system-wide            -> the user-scope assertions fail
#   - return an empty Windows plan         -> the "unsupported" assertion fails
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> checking the service-file builder"
node scripts/service/main.mjs

# And the one part that is not pure: the command reaches the dispatcher and
# refuses an action it does not have. A subcommand that exists in `usage` but
# not in the switch looks installed and does nothing, which is the thing this
# whole area is about.
CLI="$ROOT/host/cqutmux-hook/index.mjs"
node "$CLI" help | grep -q "cqutmux service install" || { echo "FAIL  service is not in help"; exit 1; }
echo "PASS  service is advertised in help"
if node "$CLI" service bogus >/dev/null 2>&1; then
  echo "FAIL  service accepted an unknown subcommand"; exit 1
fi
echo "PASS  service refuses an unknown subcommand"
node "$CLI" service status >/dev/null 2>&1 && { echo "FAIL  status claimed a service with none installed"; exit 1; }
echo "PASS  status reports no service when none is installed"

echo ""
echo "SERVICE_OK"