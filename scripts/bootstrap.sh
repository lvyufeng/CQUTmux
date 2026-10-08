#!/usr/bin/env bash
# Fetch XcodeGen (if missing) and generate CQUTmux.xcodeproj from project.yml.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/.tools"
XCODEGEN="$TOOLS/xcodegen/bin/xcodegen"

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