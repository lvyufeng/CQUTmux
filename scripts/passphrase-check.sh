#!/usr/bin/env bash
#
# Checks the app-side decisions for stored SSH keys: which stored forms are
# recognised, and what each one needs before it can authenticate.
#
# Usage: scripts/passphrase-check.sh
#
# What is asserted
# ----------------
# `KeyMaterial` decides whether the connect flow can go straight to the
# terminal, has to show a passphrase field, or has nothing to work with. Every
# branch of that decision is a real user path, and two of them are easy to get
# backwards in a way no test of the crypto would catch:
#
# 1. An encrypted key with a *stale* stored passphrase must report
#    "ask again", not "ready". Trusting the stored passphrase would fail inside
#    the SSH handshake, where the error says nothing about the passphrase.
# 2. An empty passphrase must count as absent. `KeyManagementView` probes a key
#    by parsing it with an empty passphrase to decide whether it is encrypted;
#    a reader that accepted "" would report every encrypted key as plain and
#    the passphrase field would never appear.
#
# How it runs the shipped code
# ----------------------------
# `KeyMaterial` lives in the app, not this package, but it needs
# `CQUTTransport` to exist. Rather than re-deriving the package's include paths
# by hand — which is fragile and drifts — the file is copied into the
# `PassphraseChecks` target here and built by SwiftPM, which already knows the
# dependency graph. The copy is not the source of truth: this script overwrites
# it every run and diffs it against the original, so a check can only ever be
# testing what ships.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SRC="App/Features/Security/KeyMaterial.swift"
DST="Packages/CQUTTransport/Tests/PassphraseChecks/KeyMaterial.swift"

[[ -f "$SRC" ]] || { echo "PASSPHRASE_MISSING_SOURCE" >&2; exit 1; }

# The fixtures, made here rather than committed: a private key in the
# repository is a private key in the repository, and these are throwaway.
command -v ssh-keygen >/dev/null || { echo "SKIP: no ssh-keygen to make fixtures with"; exit 0; }
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
ssh-keygen -q -t ed25519 -N "" -C "cqutmux-check" -f "$OUT/id_ed25519"
ssh-keygen -q -t ed25519 -N "a passphrase" -C "cqutmux-check" -f "$OUT/id_ed25519_encrypted"

cp "$SRC" "$DST"
if ! cmp -s "$SRC" "$DST"; then
  echo "PASSPHRASE_COPY_MISMATCH" >&2
  exit 1
fi

echo "==> building PassphraseChecks"
swift build --package-path "$ROOT/Packages/CQUTTransport" --product PassphraseChecks >/dev/null

BIN="$(swift build --package-path "$ROOT/Packages/CQUTTransport" --product PassphraseChecks --show-bin-path)/PassphraseChecks"
[[ -x "$BIN" ]] || { echo "PASSPHRASE_BUILD_FAIL" >&2; exit 1; }

KEY_IMPORT_TMPDIR="$OUT" "$BIN"