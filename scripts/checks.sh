#!/usr/bin/env bash
# Run every headless check script and summarise.
#
# This is the one command CI runs, and the one to run before a commit. Each
# check is independent and self-contained (swiftc over pure files, or node over
# pure modules), so they can be run in any order and none of them needs a
# simulator, a network, or a built .app.
#
# Scripts that do need a simulator are listed in SKIP below rather than being
# detected: detection would have to guess, and a check silently dropping out of
# the run is exactly the failure this script exists to prevent. If one of them
# ever becomes headless, remove it from SKIP deliberately.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Not headless: these boot or drive a simulator, so they cannot run on a CI box
# without one. Kept out of the run rather than allowed to fail.
SKIP=(
  scripts/jumpto-check.sh
  scripts/liveactivity-delivery-check.sh
  scripts/simulator-touch-app-check.sh
  scripts/simulator-touch-check.sh
  scripts/tab-row-check.sh
)

skip_for() {
  local want="$1" s
  for s in "${SKIP[@]}"; do [[ "$s" == "$want" ]] && return 0; done
  return 1
}

TIMEOUT="${CHECK_TIMEOUT:-600}"
pass=0
fail=0
skipped=0
failed_names=()
declare -a results=()

# Sorted so the output is stable and diffable between runs.
while IFS= read -r script; do
  name="${script#scripts/}"
  if skip_for "$script"; then
    skipped=$((skipped + 1))
    results+=("SKIP  $name")
    continue
  fi
  # `timeout` is not on macOS by default; fall back to running unbounded.
  out=""
  if command -v timeout >/dev/null 2>&1; then
    out="$(timeout "$TIMEOUT" bash "$script" 2>&1)"
  else
    out="$(bash "$script" 2>&1)"
  fi
  rc=$?
  if (( rc == 0 )); then
    pass=$((pass + 1))
    # Each check prints its own "<AREA>_PASS (N checks)" line; keep it so the
    # summary carries the check counts, not just a tick.
    last="$(printf '%s\n' "$out" | grep -E '_PASS' | tail -1)"
    results+=("ok    $name  ${last:-}")
  else
    fail=$((fail + 1))
    failed_names+=("$name")
    results+=("FAIL  $name  (exit $rc)")
  fi
done < <(ls scripts/*-check.sh | sort)

printf '%s\n' "${results[@]}"
echo

if (( fail > 0 )); then
  echo "==> $fail failed: ${failed_names[*]}"
  echo "    re-run one with: bash scripts/<name>"
  echo "CHECKS_FAIL ($pass passed, $fail failed, $skipped skipped)"
  exit 1
fi

echo "CHECKS_PASS ($pass passed, $skipped skipped)"
