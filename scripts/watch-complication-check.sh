#!/usr/bin/env bash
#
# Checks the watch face surface: the usage complication and the watch-side Live
# Activity.
#
# Usage: scripts/watch-complication-check.sh
#
# What can and cannot be checked here
# -----------------------------------
# The number the complication shows, and the container it travels through, are
# checked by scripts/watch-usage-check.sh, which runs the shared payload code
# without a simulator. What is left is the wiring that no shared code can prove:
# that a widget extension target exists for watchOS, that both it and the watch
# app carry the same App Group, that the extension is embedded in the watch app
# and the watch app in the phone app, and that the extension's `kind` and
# families are what a face would look for.
#
# What is deliberately *not* asserted: that the complication appears on a watch
# face. Placing one is a user action on the face itself, and this environment
# has no way to observe the result — so claiming it here would be claiming
# something unverified. The extension loading is checked instead, which is the
# half a build can be wrong about.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
note() { printf 'SKIP  %s\n' "$1"; }
check() { # <condition> <label>
  if [ "$1" = "1" ]; then
    printf 'PASS  %s\n' "$2"
  else
    printf 'FAIL  %s\n' "$2"
    fail=1
  fi
}

SOURCE="WatchWidgets/CQUTmuxWatchWidgets.swift"
ENT_WIDGET="WatchWidgets/CQUTmuxWatchWidgets.entitlements"
ENT_WATCH="Watch/CQUTmuxWatch.entitlements"
GROUP="group.app.cqutmux.ios"

echo "==> the complication and its target"

check "$([ -f "$SOURCE" ] && echo 1 || echo 0)" "the complication source exists"
check "$(grep -q 'StaticConfiguration(kind: "CQUTmuxUsage"' "$SOURCE" && echo 1 || echo 0)" \
  "it declares a stable widget kind"
# The four accessory families are the watch-face ones; a complication offered
# only as a Lock Screen family would never appear on a face.
for family in accessoryCircular accessoryCorner accessoryRectangular accessoryInline; do
  check "$(grep -q "\.$family" "$SOURCE" && echo 1 || echo 0)" "it supports the $family family"
done
check "$(grep -q 'cqutmux://usage' "$SOURCE" && echo 1 || echo 0)" \
  "a tap opens the Usage screen"
check "$(grep -q 'supplementalActivityFamilies' Widgets/CQUTmuxWidgets.swift && echo 1 || echo 0)" \
  "the Live Activity is offered to the watch's Smart Stack"

echo "==> the App Group both processes need"

check "$(grep -q "$GROUP" "$ENT_WIDGET" && echo 1 || echo 0)" "the extension declares the App Group"
check "$(grep -q "$GROUP" "$ENT_WATCH" && echo 1 || echo 0)" "the watch app declares the same group"
check "$(grep -q "WatchWidgets/CQUTmuxWatchWidgets.entitlements" project.yml && echo 1 || echo 0)" \
  "the extension target names its entitlements"
check "$(grep -q "Watch/CQUTmuxWatch.entitlements" project.yml && echo 1 || echo 0)" \
  "the watch target names its entitlements"
# A group declared in the entitlements but read by a different string in code is
# the failure this catches: the container is created and then never looked in.
check "$(grep -q "appGroup = \"$GROUP\"" App/Shared/WatchPayload.swift && echo 1 || echo 0)" \
  "the code reads the group the entitlements declare"

echo "==> the extension is embedded where the system looks"

WATCH_APP="build/Build/Products/Debug-watchsimulator/CQUTmuxWatch.app"
PHONE_WATCH="build/Build/Products/Debug-iphonesimulator/CQUTmux.app/Watch/CQUTmuxWatch.app"
if [ -d "$WATCH_APP" ]; then
  check "$([ -d "$WATCH_APP/PlugIns/CQUTmuxWatchWidgets.appex" ] && echo 1 || echo 0)" \
    "the extension is inside the watch app"
  check "$(plutil -extract NSExtension.NSExtensionPointIdentifier raw \
    "$WATCH_APP/PlugIns/CQUTmuxWatchWidgets.appex/Info.plist" 2>/dev/null \
    | grep -q widgetkit-extension && echo 1 || echo 0)" \
    "the extension declares the WidgetKit point"
  check "$([ -d "$PHONE_WATCH/PlugIns/CQUTmuxWatchWidgets.appex" ] && echo 1 || echo 0)" \
    "…and travels with the phone app that installs it"
else
  note "no watch build — run scripts/build.sh (the embedding checks did not run)"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "WATCH_COMPLICATION_PASS"
else
  echo "WATCH_COMPLICATION_FAIL"
  exit 1
fi