#!/usr/bin/env bash
#
# Checks Settings → Toolbar: the Glass Effect switch, its default, and that the
# setting is carried by sync as well as stored.
#
# The behaviour half is in scripts/toolbar/main.swift, which can run the store
# against a suite of its own. This wrapper adds the two things a unit check
# cannot do.
#
# First, version gating. The app builds for iOS 18, where there is no glass to
# turn off. The check binary is built for the host (macOS), where
# `#available(iOS 26.0, *)` takes its `*` branch and answers "yes" — so running
# the gate would assert the opposite of what a device on the deployment target
# sees. Instead this reads the source and the project spec: the deployment
# target has to be below 26, and the gate has to name 26.
#
# Second, sync. A setting is carried by BOTH the store and the sync payload, and
# forgetting the payload half is invisible — the switch still works on the
# device it was flipped on, and simply never travels. That is a pairing of
# names, not behaviour, so it is checked by reading the real sources rather than
# by compiling half the app.
#
# `ToolbarSettings.swift` imports SwiftUI only for `#available`, so no simulator
# is needed.
#
# Usage: scripts/toolbar-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Features/Settings/ToolbarSettings.swift" \
  "$ROOT/scripts/toolbar/main.swift" 2>&1 | grep -vE "warning:" || true

[[ -x "$OUT/check" ]] || { echo "TOOLBAR_BUILD_FAIL"; exit 1; }
"$OUT/check" | tee "$OUT/results"

MISSING=0
note() { echo "$1"; MISSING=1; }

# MARK: - The gate is reachable

SETTINGS="$ROOT/App/Features/Settings/ToolbarSettings.swift"
SPEC="$ROOT/project.yml"

grep -q 'available(iOS 26' "$SETTINGS" \
  || note "FAIL  canTurnOffGlass does not name iOS 26"

# The gate is only ever false if the target is below it. If the deployment
# target is raised to 26 the switch becomes unconditional, and the screen's
# "this system cannot do that" footer becomes a lie.
target=$(awk '/^  deploymentTarget:/{getline; print}' "$SPEC" \
  | grep -oE 'iOS: "[0-9.]+"' | grep -oE '[0-9]+')
case "$target" in
  [0-9]*) ;;
  *) note "FAIL  could not read the iOS deployment target from project.yml" ;;
esac
if [[ "$target" =~ ^[0-9]+$ ]] && (( target >= 26 )); then
  note "FAIL  deployment target is iOS $target; the below-26 branch and its footer are now dead"
fi

# MARK: - The setting is carried by sync as well as stored

STORES="$ROOT/App/Features/Settings/SyncStores.swift"
PAYLOAD="$ROOT/App/Features/Settings/SettingsSync.swift"

# Fields of `SyncPayload` only. Other types in the same file have properties of
# their own (`isEnabled` is the sync manager's, not something that travels), and
# matching those would report fields that are correct as missing.
payloadFields() {
  awk '/^struct SyncPayload/{inside=1; next} inside && /^}/{exit} inside' "$PAYLOAD" \
    | grep -oE '^ +var [a-zA-Z]+: ' | awk '{print $2}' | tr -d ':'
}

# Every setting the store holds should have a field on the payload, be captured
# into it, and be applied back out of it.
for field in glassEffect; do
  grep -q "payload\.$field = stores\." "$STORES" \
    || note "FAIL  $field is never captured into the sync payload"
  grep -qE "^ *var $field: " "$PAYLOAD" \
    || note "FAIL  $field is absent from SyncPayload"
  grep -q "if let $field {" "$STORES" \
    || note "FAIL  $field is never applied back from a payload"
done

# And the reverse, which is the direction that actually bites: a field added to
# the payload and honoured nowhere is a setting that syncs into a void.
for field in $(payloadFields); do
  case "$field" in
    version|hosts|importedThemes) continue ;;  # applied wholesale, not per-field
  esac
  grep -q "\.$field" "$STORES" \
    || note "FAIL  SyncPayload.$field is never read or written by SyncStores"
done

if [[ "$MISSING" -eq 0 ]]; then
  echo "PASS  the gate is reachable and every synced setting is captured, stored and applied"
else
  exit 1
fi

# Not `grep … && exit 1`: a failing grep there is the last status of an AND-list
# and `set -e` reads it as an error, so a passing run would exit 1.
if grep -q '^FAIL' "$OUT/results"; then
  exit 1
fi

printf '\nTOOLBAR_PASS\n'