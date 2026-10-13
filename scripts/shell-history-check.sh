#!/usr/bin/env bash
#
# Checks the command-history reader: the parser for `~/.zsh_history` and its
# bash counterpart, which the terminal's History key is fed from.
#
# A mis-parsed history does not error — it offers the user a command that is
# subtly not the one they ran, and that command gets typed into a shell and
# run. So the escaping rules get a script of their own.
#
# The assertions live in `scripts/shell-history/main.mjs` rather than in a
# heredoc here: the fixtures are mostly backslashes and quotes, and nesting
# them inside a bash double-quoted string makes the test's own escaping harder
# to read than the code it is testing.
#
# Usage: scripts/shell-history-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

node "$ROOT/scripts/shell-history/main.mjs" "$OUT"