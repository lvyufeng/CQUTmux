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

# The one check that cannot run inside the loop: half of it holds the counts
# quoted in docs/parity-audit.json against the counts this run printed, so it
# has to start after every other check has finished. It is excluded from the
# loop by name here — deliberately, and visibly — and run once below, where its
# result joins the summary like any other pass.
AUDIT_CHECK=scripts/audit-check.sh

skip_for() {
  local want="$1" s
  for s in "${SKIP[@]}"; do [[ "$s" == "$want" ]] && return 0; done
  return 1
}

TIMEOUT="${CHECK_TIMEOUT:-600}"
# How much of a failing check's own output to keep. A check that fails prints
# the reason; without it the summary names the check and nothing else, which
# is the moment someone is looking. Capped so one chatty check cannot bury
# every other result.
FAIL_LINES=25
pass=0
fail=0
skipped=0
failed_names=()
declare -a results=()
declare -a failed_output=()

# What each check printed as its own count, for the audit check to compare the
# numbers docs/parity-audit.json quotes against. Two checks print no count
# (toolbar-check.sh, watch-complication-check.sh); they simply have no line here.
COUNTS="$(mktemp)"
trap 'rm -f "$COUNTS"' EXIT

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
    # summary carries the check counts, not just a tick. The last line that
    # *carries* a count rather than simply the last line: locale-check.sh prints
    # its count from the node half and then a plain verdict from the shell half,
    # and a check whose count exists should not read as one that has none.
    last="$(printf '%s\n' "$out" | grep -E '_PASS.*\([0-9]+ checks?\)' | tail -1)"
    [[ -n "$last" ]] || last="$(printf '%s\n' "$out" | grep -E '_PASS' | tail -1)"
    results+=("ok    $name  ${last:-}")
    count="$(printf '%s\n' "$last" | grep -oE '\([0-9]+ checks?\)' | tail -1 | grep -oE '[0-9]+' || true)"
    [[ -n "$count" ]] && printf '%s %s\n' "$name" "$count" >> "$COUNTS"
  else
    fail=$((fail + 1))
    failed_names+=("$name")
    results+=("FAIL  $name  (exit $rc)")
    failed_output+=("$(printf '%s\n' "$name (exit $rc)" \
      "$(printf '%s\n' "$out" | tail -n "$FAIL_LINES")")")
  fi
done < <(ls scripts/*-check.sh | grep -v "^$AUDIT_CHECK$" | sort)

# Last, with what the run above measured.
audit_out=""
if audit_out="$(bash "$AUDIT_CHECK" --observed "$COUNTS" 2>&1)"; then
  pass=$((pass + 1))
  results+=("ok    ${AUDIT_CHECK#scripts/}  $(printf '%s\n' "$audit_out" | grep -E '_PASS' | tail -1)")
else
  rc=$?
  fail=$((fail + 1))
  failed_names+=("${AUDIT_CHECK#scripts/}")
  results+=("FAIL  ${AUDIT_CHECK#scripts/}  (exit $rc)")
  failed_output+=("$(printf '%s\n' "${AUDIT_CHECK#scripts/} (exit $rc)" \
    "$(printf '%s\n' "$audit_out" | tail -n "$FAIL_LINES")")")
fi

printf '%s\n' "${results[@]}"
echo

if (( fail > 0 )); then
  echo "==> $fail failed: ${failed_names[*]}"
  echo
  for blob in "${failed_output[@]}"; do
    printf '%s\n' "$blob" | sed 's/^/    /'
    echo
  done
  echo "    re-run one with: bash scripts/<name>"
  echo "CHECKS_FAIL ($pass passed, $fail failed, $skipped skipped)"
  exit 1
fi

echo "CHECKS_PASS ($pass passed, $skipped skipped)"
