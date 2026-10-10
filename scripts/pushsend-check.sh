#!/bin/sh
# What the gateway actually sends to APNs, against a local HTTP/2 server.
set -e
cd "$(dirname "$0")/.."
node scripts/pushsend/check.mjs
