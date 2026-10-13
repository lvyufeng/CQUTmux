#!/usr/bin/env bash
# Fetch XcodeGen (if missing) and generate CQUTmux.xcodeproj from project.yml.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/.tools"
XCODEGEN="$TOOLS/xcodegen/bin/xcodegen"

# The lock is shared with build.sh, which holds it across the whole build: a
# build that reads the project while another run has just regenerated it fails
# in ways that read as source errors. build.sh sets the flag after taking the
# lock itself, so the two are one critical section rather than a nested pair.
if [[ "${CQUTMUX_LOCK_HELD:-}" != "1" ]]; then
  mkdir -p "$TOOLS"
  LOCK="$TOOLS/.xcodegen.lock"
  waited=0
  until mkdir "$LOCK" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if (( waited >= 300 )); then
      echo "==> gave up waiting for $LOCK after ${waited}s" >&2
      echo "    if no build is running, remove it: rm -rf '$LOCK'" >&2
      exit 1
    fi
  done
  # Registered only once the lock is ours, so the timeout path above cannot
  # release a lock it never took.
  trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
fi

if [[ ! -x "$XCODEGEN" ]]; then
  if command -v xcodegen >/dev/null 2>&1; then
    XCODEGEN="$(command -v xcodegen)"
  else
    echo "==> xcodegen not found, downloading standalone binary"
    mkdir -p "$TOOLS"
    tmp="$(mktemp -d)"
    url="https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip"
    curl -fsSL "$url" -o "$tmp/xcodegen.zip"
    mkdir -p "$tmp/extract"
    unzip -q "$tmp/xcodegen.zip" -d "$tmp/extract"
    rm -rf "$TOOLS/xcodegen"
    mkdir -p "$TOOLS/xcodegen"
    # The release zip nests everything under a top-level xcodegen/ directory.
    if [[ -d "$tmp/extract/xcodegen" ]]; then
      cp -R "$tmp/extract/xcodegen/." "$TOOLS/xcodegen/"
    else
      cp -R "$tmp/extract/." "$TOOLS/xcodegen/"
    fi
    rm -rf "$tmp"
    chmod +x "$TOOLS/xcodegen/bin/xcodegen" 2>/dev/null || true
  fi
fi

echo "==> generating project"
cd "$ROOT"
"$XCODEGEN" generate
echo "==> done: CQUTmux.xcodeproj"