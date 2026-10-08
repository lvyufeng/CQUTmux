#!/usr/bin/env bash
# Build, install and launch CQUTmux on a booted simulator.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEVICE="${DEVICE:-iPhone 18 Pro}"
"$ROOT/scripts/build.sh"

APP="$(find build/Build/Products -name 'CQUTmux.app' -maxdepth 3 | head -1)"
[[ -n "$APP" ]] || { echo "app not found"; exit 1; }

UDID="$(xcrun simctl list devices available | grep -m1 "$DEVICE (" | grep -oE '[0-9A-F-]{36}')"
[[ -n "$UDID" ]] || { echo "simulator '$DEVICE' not found"; exit 1; }

echo "==> booting $DEVICE ($UDID)"
xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator

echo "==> installing"
xcrun simctl install "$UDID" "$APP"

echo "==> launching"
xcrun simctl launch "$UDID" app.cqutmux.ios