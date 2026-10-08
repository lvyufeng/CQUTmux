#!/bin/bash
#
# Build mosh's client-side libraries for the iOS simulator (arm64).
#
# This does not run autoconf. mosh's configure probes for the *server's*
# dependencies — pty.h, utempter, libutil, utmpx — none of which exist on iOS,
# so it would either fail outright or enable code that cannot link. Instead
# this compiles the client libraries directly against a hand-written config
# (config-ios.h), with crypto on Apple Common Crypto and terminfo replaced by
# a compiled-in entry. See those files for why each choice was made.
#
# Server-side translation units are excluded on purpose: we are a client.
#
# Usage: scripts/mosh-ios/build.sh <mosh-source-dir> <out-dir> [protoc-dir]
# Env:   PLATFORM=simulator (default) | device
set -euo pipefail

MOSH_SRC="${1:?usage: build.sh <mosh-source-dir> <out-dir> [protoc-dir]}"
OUT="${2:?usage: build.sh <mosh-source-dir> <out-dir> [protoc-dir]}"
# protoc generate step; fetch-deps.sh puts it next to the sources.
PROTOC_DIR="${3:-$(dirname "$MOSH_SRC")/protoc/bin}"
HERE="$(cd "$(dirname "$0")" && pwd)"
export PATH="$PROTOC_DIR:$PATH"

# Which SDK to build against. Both are needed — the app has to link for the
# simulator to be testable and for a device to be runnable or shipped — so this
# is a choice rather than a constant. An environment variable because the
# positional arguments are already spoken for.
PLATFORM="${PLATFORM:-simulator}"
case "$PLATFORM" in
  simulator) SDK_NAME=iphonesimulator; TARGET="arm64-apple-ios18.0-simulator" ;;
  device)    SDK_NAME=iphoneos;        TARGET="arm64-apple-ios18.0" ;;
  *) echo "unknown platform '$PLATFORM' (expected simulator or device)" >&2; exit 2 ;;
esac

SDK="$(xcrun --sdk "$SDK_NAME" --show-sdk-path)"
PROTOBUF_INC="${PROTOBUF_INC:-$(dirname "$MOSH_SRC")/protobuf-21.12/src}"

# protobuf's generated .pb.cc files (produced by protoc, which autoconf would
# normally invoke through pkg-config) have to be compiled in too.
PB_GEN="$OUT/pbgen"

# The driver's public header is owned by the SwiftPM package, so the app and
# this script cannot drift apart on what the C surface is.
DRIVER_INCLUDE="$HERE/../../Packages/CQUTMosh/Sources/CQUTMoshC/include"

INCLUDES=(
  -I"$DRIVER_INCLUDE"
  -I"$HERE/include"
  -I"$HERE"
  -I"$MOSH_SRC/src/include"
  -I"$MOSH_SRC/src/protobufs"
  -I"$PB_GEN"
)
# mosh's automake adds each subdirectory to the include path, so headers are
# included by bare name (fatal_assert.h, swrite.h, select.h…). Mirror that.
for dir in crypto util statesync network terminal protobufs; do
  INCLUDES+=(-I"$MOSH_SRC/src/$dir")
done
[ -n "$PROTOBUF_INC" ] && INCLUDES+=(-I"$PROTOBUF_INC")

# -fno-exceptions is NOT used: mosh throws for terminfo and framing errors and
# we want those to reach the Swift boundary as errors, not abort().
CXXFLAGS=(
  -isysroot "$SDK" -target "$TARGET"
  -std=c++17 -O2 -fPIC
  -Wall -Wno-unused-parameter -Wno-deprecated-declarations
  -DHAVE_CONFIG_H
  "${INCLUDES[@]}"
)

CFLAGS=(
  -isysroot "$SDK" -target "$TARGET"
  -O2 -fPIC -Wall
  "${INCLUDES[@]}"
)

rm -rf "$OUT"
mkdir -p "$OUT/obj" "$PB_GEN" "$OUT/lib"

echo "==> generating protobuf sources"
for proto in userinput hostinput transportinstruction; do
  protoc --proto_path="$MOSH_SRC/src/protobufs" \
         --cpp_out="$PB_GEN" \
         "$MOSH_SRC/src/protobufs/$proto.proto"
done

# Directories holding the client build. 'frontend' is reduced to the pieces a
# driver can use; its main() lives in stmclient.cc, which we replace.
SRC_DIRS=(crypto util statesync network terminal protobufs)
# Files that belong to the server or to a main() we do not want, plus the
# crypto backends automake would have conditionally excluded. ocb_openssl.cc
# is selected by USE_AES_OCB_FROM_OPENSSL; we use ocb_internal.cc instead
# (apple-common-crypto), and ocb_openssl.cc would drag in OpenSSL — the exact
# cross-compile this whole approach avoids.
EXCLUDE_RE='mosh-server|mosh-client|stmclient|networktransport-dummy|ocb_openssl|ocb_nettle|networktransport-\w*\.cc|pty_compat'

echo "==> compiling mosh client libraries"
# read lines into an array without mapfile (absent in the bash 3.2 macOS ships)
SOURCES=()
while IFS= read -r line; do
  [ -n "$line" ] && SOURCES+=("$line")
done < <(
  find "${SRC_DIRS[@]/#/$MOSH_SRC/src/}" -name '*.cc' 2>/dev/null \
    | grep -vE "$EXCLUDE_RE" | sort
)
PROTO_SOURCES=$(find "$PB_GEN" -name '*.pb.cc' | sort)
SOURCES+=($PROTO_SOURCES)

CSOURCES=$(find "$HERE" -name '*.c')

i=0
for src in "${SOURCES[@]}"; do
  obj="$OUT/obj/$(echo "${src#$MOSH_SRC/}" | tr '/' '_').o"
  echo "    $(basename "$src")"
  xcrun --sdk "$SDK_NAME" clang++ "${CXXFLAGS[@]}" -c "$src" -o "$obj" || exit 1
  i=$((i + 1))
done
for src in $CSOURCES; do
  obj="$OUT/obj/$(basename "$src").o"
  echo "    $(basename "$src")"
  xcrun --sdk "$SDK_NAME" clang "${CFLAGS[@]}" -c "$src" -o "$obj" || exit 1
done

echo "==> compiling the CQUTMosh driver"
# It needs mosh's headers, which only exist here, so it is built with the rest
# rather than as a SwiftPM target — SwiftPM has no way to see this tree.
DRIVER="$HERE/driver/mosh_driver.cc"
if [ -f "$DRIVER" ]; then
  xcrun --sdk "$SDK_NAME" clang++ "${CXXFLAGS[@]}" \
    -c "$DRIVER" -o "$OUT/obj/cqutmosh_driver.o"
fi

echo "==> archiving"
xcrun --sdk "$SDK_NAME" libtool -static -o "$OUT/lib/libmoshclient.a" "$OUT"/obj/*.o

echo "==> done: $OUT/lib/libmoshclient.a"
# Count defined C++ symbols as a sanity check that the archive is not empty.
# `|| true` because grep -c exits 1 on a zero count, which set -e would take
# as a build failure — the opposite of what a zero here means.
count=$(xcrun --sdk "$SDK_NAME" nm -g "$OUT/lib/libmoshclient.a" 2>/dev/null \
  | grep -cE ' T __ZN' || true)
echo "    defined C++ symbols: $count"
[ "$count" -gt 0 ] || { echo "archive is empty"; exit 1; }