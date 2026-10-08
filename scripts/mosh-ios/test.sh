#!/bin/bash
#
# End-to-end check: the iOS mosh client, running as an arm64 iOS binary,
# completes a handshake with a real mosh-server and decodes its output.
#
# This is the check that matters — an archive full of symbols proves nothing
# about whether the crypto, framing and state sync actually work.
#
# Needs a mosh-server. macOS has none by default; the official release .pkg
# contains one, and it is a universal binary:
#
#   curl -sSL -o /tmp/mosh.pkg \
#     https://github.com/mobile-shell/mosh/releases/download/mosh-1.4.0/mosh-1.4.0.pkg
#   mkdir -p /tmp/pkgx && (cd /tmp/pkgx && xar -xf /tmp/mosh.pkg)
#   mkdir -p /tmp/pkgx/edu.mit.mosh.mosh.pkg/ext
#   tar xzf /tmp/pkgx/edu.mit.mosh.mosh.pkg/Payload -C /tmp/pkgx/edu.mit.mosh.mosh.pkg/ext
#
# Usage: scripts/mosh-ios/test.sh <workdir> <mosh-server> [device-udid]
set -euo pipefail

WORK="${1:?usage: test.sh <workdir> <mosh-server> [device-udid]}"
MOSH_SERVER="${2:?usage: test.sh <workdir> <mosh-server> [device-udid]}"
DEVICE="${3:-$(xcrun simctl list devices booted -j | python3 -c \
  "import json,sys; d=json.load(sys.stdin)['devices']; print([x['udid'] for v in d.values() for x in v if x['state']=='Booted'][0])")}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$WORK/mosh-1.4.0/src"

"$HERE/build.sh" "$WORK/mosh-1.4.0" "$WORK/out" "$WORK/protoc/bin"

INC=(-I"$HERE/../../Packages/CQUTMosh/Sources/CQUTMoshC/include"
     -I"$HERE/include"
     -I"$SRC/statesync" -I"$SRC/network" -I"$SRC/protobufs"
     -I"$SRC/util" -I"$SRC/crypto" -I"$SRC/terminal"
     -I"$WORK/out/pbgen" -I"$WORK/protobuf-21.12/src")
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET=arm64-apple-ios18.0-simulator
DRIVER="$HERE/driver/mosh_driver.cc"

echo "==> building the driver and the test harness"
xcrun --sdk iphonesimulator clang++ -isysroot "$SDK" -target "$TARGET" \
  -std=c++17 -O1 -Wno-deprecated-declarations -DHAVE_CONFIG_H \
  -I"$(dirname "$DRIVER")" "${INC[@]}" -c "$DRIVER" -o "$WORK/driver.o"

xcrun --sdk iphonesimulator clang++ -isysroot "$SDK" -target "$TARGET" \
  -std=c++17 -O1 -Wno-deprecated-declarations -DHAVE_CONFIG_H \
  -I"$(dirname "$DRIVER")" "${INC[@]}" "$HERE/e2e-test.cc" "$WORK/driver.o" \
  "$WORK/out/lib/libmoshclient.a" \
  "$WORK/protobuf-21.12/build-ios/libprotobuf-lite.a" \
  -lz -lc++ -framework CoreFoundation -o "$WORK/moshtest"

echo "==> starting mosh-server"
pkill -f mosh-server 2>/dev/null || true
sleep 1
# The session command has to read its stdin: `exec sh` replaces the -c shell
# with one that executes whatever is typed, so the input test below sees the
# command's output come back. A session command that does not read — `sleep`,
# say — swallows the typed line and looks exactly like a broken input path.
"$MOSH_SERVER" new -c 256 -- sh -c 'echo MOSH_E2E_OK; exec sh' \
  >"$WORK/srv.out" 2>&1 &
sleep 3
CONNECT=$(grep 'MOSH CONNECT' "$WORK/srv.out" | head -1)
[ -n "$CONNECT" ] || { echo "mosh-server never reported a port"; exit 1; }
PORT=$(echo "$CONNECT" | awk '{print $3}')
KEY=$(echo "$CONNECT" | awk '{print $4}')
echo "    $CONNECT"

echo "==> running the iOS client against it"
# The harness exits non-zero on its own for either half failing, so the exit
# status is the verdict. The greps are a second opinion on the transcript, in
# case the exit status is ever reported for the wrong reason.
if xcrun simctl spawn "$DEVICE" "$WORK/moshtest" "$KEY" 127.0.0.1 "$PORT" | tee "$WORK/e2e.out"; then
  grep -q 'TYPED_24_OK' "$WORK/e2e.out" \
    && echo "==> PASS: session up, output decoded, keystrokes ran on the server" \
    || { echo "==> FAIL: no input round-trip in the transcript"; exit 1; }
else
  echo "==> FAIL"
  exit 1
fi
pkill -f mosh-server 2>/dev/null || true