#!/usr/bin/env bash
# Build CQUTmux for the iOS simulator.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[[ -d CQUTmux.xcodeproj ]] || "$ROOT/scripts/bootstrap.sh"

DEST="${DEST:-platform=iOS Simulator,name=iPhone 18 Pro}"

xcodebuild \
  -project CQUTmux.xcodeproj \
  -scheme CQUTmux \
  -destination "$DEST" \
  -derivedDataPath build \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  build