#!/bin/sh
# The host's Live Activity steering: what a push does, and what it carries.
set -e
cd "$(dirname "$0")/.."
node scripts/liveactivity/check.mjs
