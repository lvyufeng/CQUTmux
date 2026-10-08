#!/bin/bash
#
# End-to-end check: the iOS ET client, running as an arm64 iOS binary, completes
# Eternal Terminal's handshake with a real etserver and drives a real shell.
#
# This is the check that matters. libetcore.a exporting et_start proves nothing
# about whether the crypto handshake completes or whether the console seam feeds
# input through; only a live server does.
#
# Needs ET's host binaries. ET publishes no macOS release asset, so they are
# built from source — see scripts/et-ios/host-tools.sh, which also documents the
# three dependency problems that build has to get past.
#
# Usage: scripts/et-ios/test.sh <workdir> <et-source-dir> <libsodium-dir> <etserver-binary> [device-udid]
set -euo pipefail

WORK="${1:?usage: test.sh <workdir> <et-source-dir> <libsodium-dir> <etserver> [device-udid]}"
ET_SRC="${2:?usage: test.sh <workdir> <et-source-dir> <libsodium-dir> <etserver> [device-udid]}"
SODIUM="${3:?usage: test.sh <workdir> <et-source-dir> <libsodium-dir> <etserver> [device-udid]}"
ETSERVER="${4:?usage: test.sh <workdir> <et-source-dir> <libsodium-dir> <etserver> [device-udid]}"
DEVICE="${5:-$(xcrun simctl list devices booted -j | python3 -c \
  "import json,sys; d=json.load(sys.stdin)['devices']; print([x['udid'] for v in d.values() for x in v if x['state']=='Booted'][0])")}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DRIVER="$HERE/driver"

PORT="${ET_TEST_PORT:-2022}"

echo "==> building ET's client core for the simulator"
"$HERE/build.sh" "$ET_SRC" "$SODIUM" "$WORK/out" simulator >/dev/null
BUILT="$WORK/out"

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET=arm64-apple-ios18.0-simulator
# ET's generated protobuf sources use the full runtime, not lite: they call
# MessageLite::SerializeToString and the descriptors' Name() accessors. The
# full runtime is what mosh's build did not need; it has to be built here.
PROTOBUF_LIB="${PROTOBUF_LIB:-/tmp/moshbuild/protobuf-21.12/build-ios/libprotobuf.a}"
[ -f "$PROTOBUF_LIB" ] || {
  echo "no full protobuf runtime at $PROTOBUF_LIB (mosh's build only makes -lite)" >&2
  exit 1
}
INC=(-I"$DRIVER" -I"$ET_SRC/src/base" -I"$ET_SRC/src/terminal"
     -I"$ET_SRC/external" -I"$ET_SRC/external/easyloggingpp/src"
     -I"$ET_SRC/external/json/single_include" -I"$ET_SRC/external/PlatformFolders"
     -I"$ET_SRC/external/msgpack-c/include" -I"$ET_SRC/external/simpleini"
     -I"$ET_SRC/external/cpp-httplib" -I"$ET_SRC/external/cxxopts/include"
     -I"$ET_SRC/external/sole" -I"$ET_SRC/external/base64"
     -I"$ET_SRC/external/UniversalStacktrace/ust" -I"$ET_SRC/external/ThreadPool"
     -I"$SODIUM/include" -I"$BUILT/pb")

echo "==> building the test harness"
xcrun --sdk iphonesimulator clang++ -isysroot "$SDK" -target "$TARGET" \
  -std=c++17 -O1 -DNO_TELEMETRY -DET_IOS=1 -Wno-deprecated-declarations \
  "${INC[@]}" "$HERE/e2e-test.cc" "$BUILT/libetcore.a" \
  "$PROTOBUF_LIB" "$SODIUM/lib/libsodium.a" \
  -lz -lresolv -lc++ -framework CoreFoundation \
  -o "$WORK/ettest"

echo "==> starting etserver on :$PORT"
pkill -f "etserver --port $PORT" 2>/dev/null || true
sleep 1
mkdir -p "$WORK/etlog" "$WORK/etrun"
"$ETSERVER" --port "$PORT" --pidfile "$WORK/etrun/etserver.pid" \
  --logdir "$WORK/etlog" >"$WORK/etserver.out" 2>&1 &
SERVER_JOB=$!
sleep 3
if ! lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "etserver never listened on $PORT:"; cat "$WORK/etserver.out"; exit 1
fi

echo "==> starting etterminal over a pty (this stands in for the app's SSH bootstrap)"
# The app runs this through an ExecRequest on its existing SSH session; here the
# hop is local, but the contract is identical: write <id>/<passkey>_<TERM> to
# etterminal's stdin and read back the "IDPASSKEY:<id>/<passkey>" it prints.
# Generated in Python rather than with `tr </dev/urandom | head -c N`: under
# `set -o pipefail` that idiom is fatal, because head exits early and tr dies of
# SIGPIPE, which takes the whole script down with it.
randalnum() {
  python3 -c "import secrets,string,sys; a=string.ascii_letters+string.digits; \
sys.stdout.write(''.join(secrets.choice(a) for _ in range(int(sys.argv[1]))))" "$1"
}
ID="XXX$(randalnum 13)"
PASSKEY="$(randalnum 32)"

printf '%s/%s_xterm-256color\n' "$ID" "$PASSKEY" > "$WORK/etrun/stdin"
# etterminal daemonizes itself, and a pty is what lets it detach without the
# SIGHUP a plain pipe job would get. `script` supplies one.
script -q /dev/null sh -c \
  "cat '$WORK/etrun/stdin' | '$ET_SRC/build-host/etterminal' --logdir '$WORK/etlog'" \
  > "$WORK/etterminal.out" 2>&1
sleep 2
BANNER=$(grep -o 'IDPASSKEY:[^ ]*' "$WORK/etterminal.out" | head -1 || true)
if [ -z "$BANNER" ]; then
  echo "etterminal never reported IDPASSKEY:"; cat "$WORK/etterminal.out"; exit 1
fi
echo "    $BANNER"
# The server mints its own credentials (that is what the XXX prefix asks for),
# so the pair to connect with is whatever the banner carries, not what was
# written in. The trailing CR matters: `script` gives etterminal a pty, which
# translates its "\n" to "\r\n", and a passkey with a CR on the end is 33 bytes
# where the crypto expects 32 — the handshake then fails with a generic connect
# timeout that says nothing about the real cause.
REAL_ID=$(printf '%s' "$BANNER" | sed -n 's/^IDPASSKEY:\([^/]*\)\/.*/\1/p' | tr -d '\r')
REAL_PASS=$(printf '%s' "$BANNER" | sed -n 's/^IDPASSKEY:[^/]*\/\(.*\)$/\1/p' | tr -d '\r')

echo "==> running the iOS client against it"
if xcrun simctl spawn "$DEVICE" "$WORK/ettest" "$REAL_ID" "$REAL_PASS" 127.0.0.1 "$PORT" \
     | tee "$WORK/et-e2e.out"; then
  grep -q 'ET_E2E_PASS' "$WORK/et-e2e.out" \
    && echo "==> PASS: handshake, output decoded, keystrokes ran, resize survived" \
    || { echo "==> FAIL: no resize round-trip in the transcript"; exit 1; }
else
  echo "==> FAIL"
  exit 1
fi
# etserver daemonizes, so the job here is the short-lived parent; the real
# server is found by command line. `wait` keeps the shell from printing a
# "Terminated" notice for the job it started.
kill "$SERVER_JOB" 2>/dev/null || true
wait "$SERVER_JOB" 2>/dev/null || true
pkill -f "etserver --port $PORT" 2>/dev/null || true
pkill -f etterminal 2>/dev/null || true