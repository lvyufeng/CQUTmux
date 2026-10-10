#!/bin/sh
# Browsing a repository at a past commit: the tree and file rules.
set -e
cd "$(dirname "$0")/.."
node scripts/gitdir/check.mjs
