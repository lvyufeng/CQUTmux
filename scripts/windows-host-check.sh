#!/usr/bin/env bash
#
# Checks the native-Windows decisions in `host/cqutmux-hook/platform.mjs`.
#
# Usage: scripts/windows-host-check.sh
#
# What is asserted
# ----------------
# The gateway runs on Linux and macOS in this repo and has never run on
# Windows, so the Windows branch cannot be exercised end to end here. What can
# be checked is the *decision* — which program to run, with which arguments, and
# where the socket lives — because `platform.mjs` is pure: it takes a platform
# string and returns a description, and spawns nothing. That is the whole reason
# the decisions were lifted out of `herdr.mjs` into it.
#
# 1. On Windows, resolution goes through `powershell` with `Get-Command`, not
#    the bare name — `execFile('herdr', …)` never finds `herdr.exe`.
# 2. On POSIX, resolution is `command -v` through `sh`; the bare name is fine.
# 3. The socket path is a named pipe on Windows and
#    `~/.config/herdr/herdr.sock` elsewhere. Getting this wrong is a connection
#    refused on the one platform nobody is looking at.
# 4. The pipe name is derived from the account, so two users on one machine do
#    not collide, and is sanitised so a name with a separator cannot escape into
#    a different pipe.
#
# The assertions live in `scripts/windows-host/main.mjs` rather than inline
# here: the Windows pipe path is all backslashes, and getting them through
# bash's own escaping without a mismatch is more error-prone than reading them
# from a file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> checking the Windows/POSIX resolution decisions"
node scripts/windows-host/main.mjs
echo "WINDOWS_HOST_OK"