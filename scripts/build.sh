#!/usr/bin/env bash
# Build CQUTmux for the iOS simulator.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# One build at a time, machine-wide. Sharing a DerivedData directory between
# two concurrent `xcodebuild` runs is not a slow build but a broken one: each
# deletes the other's half-written products, and the failure surfaces as a
# random "no such module" or a stale-interface error that reads like a source
# mistake. Serialising also keeps the incremental cache warm across callers,
# which makes the second build far cheaper than a parallel pair would be.
# Held across generation too, since a build reading the project while another
# run regenerates it fails the same way.
mkdir -p "$ROOT/.tools"
LOCK="$ROOT/.tools/.xcodegen.lock"
waited=0
until mkdir "$LOCK" 2>/dev/null; do
  if (( waited == 0 )); then
    echo "==> another build holds the lock; waiting"
  fi
  sleep 2
  waited=$((waited + 2))
  if (( waited >= 2400 )); then
    echo "==> gave up waiting for $LOCK after ${waited}s" >&2
    echo "    if no build is running, remove it: rm -rf '$LOCK'" >&2
    exit 1
  fi
done
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
export CQUTMUX_LOCK_HELD=1

# Always regenerate. XcodeGen writes an explicit file reference per source, so
# a file added since the last generate is silently absent from the build — the
# symptom is a missing symbol somewhere far from the file that caused it.
"$ROOT/scripts/bootstrap.sh"

DEST="${DEST:-platform=iOS Simulator,name=iPhone 18 Pro}"

# Where derived data goes. Overridable, but leaving it shared is what makes the
# serialised builds incremental; the lock above is what makes that safe.
DD="${DD:-$ROOT/build}"

xcodebuild \
  -project CQUTmux.xcodeproj \
  -scheme CQUTmux \
  -destination "$DEST" \
  -derivedDataPath "$DD" \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  PROVISIONING_PROFILE_SPECIFIER= \
  build