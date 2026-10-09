#!/bin/bash
#
# Build whisper.cpp's speech-to-text core for iOS.
#
# whisper.cpp already ships build-xcframework.sh, which produces a full
# whisper.framework. That is not the right shape here for two reasons:
#
#   1. It builds iOS device, macOS, visionOS and tvOS as well — four toolchains
#      for the one platform this app runs on, plus a dSYM/codesign/XCFramework
#      dance around them.
#   2. It makes a *dynamic* framework. We link statically, like libsodium and
#      libetcore do, so nothing new has to be embedded or re-signed.
#
# So this drives the same CMake configure the upstream script drives for its
# iOS-simulator slice, then keeps the six static archives it emits. The
# upstream arguments are copied rather than guessed at: in particular
# GGML_METAL_EMBED_LIBRARY, which compiles the Metal shader source into the
# archive so the app does not have to ship a .metal file and compile it at
# launch.
#
# The GPU matters here. On a phone-sized model the CPU path is the difference
# between a dictation that feels immediate and one that makes the user wait;
# Moshi's own docs sell on-device speech as "no cloud, no latency", which the
# CPU backend alone would not honestly be able to claim.
#
# cmake is not on PATH on this machine (and not installable via brew). It is
# available as `python3 -m cmake`, so PATH=${HOME}/.local/bin:$PATH is assumed,
# where a two-line shim provides it.
#
# Usage: scripts/whisper-ios/build.sh <whisper-source-dir> <out-dir> [simulator|device]
set -euo pipefail

SRC="${1:?usage: build.sh <whisper-source-dir> <out-dir> [simulator|device]}"
OUT="${2:?usage: build.sh <whisper-source-dir> <out-dir> [simulator|device]}"
PLATFORM="${3:-simulator}"
HERE="$(cd "$(dirname "$0")" && pwd)"

case "$PLATFORM" in
  simulator) SDK=iphonesimulator; ARCHS="arm64"; PLATFORM_NAME=iphonesimulator ;;
  device)    SDK=iphoneos;        ARCHS="arm64"; PLATFORM_NAME=iphoneos ;;
  *) echo "unknown platform '$PLATFORM'" >&2; exit 2 ;;
esac

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

echo "==> configuring whisper.cpp for $PLATFORM"
cmake -B "$BUILD/build" -G Xcode \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 \
  -DIOS=ON \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$SDK" \
  -DCMAKE_OSX_ARCHITECTURES="$ARCHS" \
  -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS="$PLATFORM_NAME" \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="" \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_BLAS_DEFAULT=ON \
  -DGGML_METAL_USE_BF16=ON \
  -DGGML_OPENMP=OFF \
  -DGGML_NATIVE=OFF \
  -DWHISPER_COREML=OFF \
  -S "$SRC" >/dev/null

echo "==> building"
cmake --build "$BUILD/build" --config Release --target whisper -- -quiet

# $OUT is the vendor root, not the platform directory: archives land in
# $OUT/$PLATFORM_NAME/ and the headers in $OUT/include/, shared between slices
# because they are the same file for both. That is the layout Vendor/etclient
# already uses, and it is what OTHER_LDFLAGS in project.yml expects.
rm -rf "$OUT/$PLATFORM_NAME"
mkdir -p "$OUT/$PLATFORM_NAME" "$OUT/include"

LIBDIR="$BUILD/build"
for lib in \
  "src/Release-$PLATFORM_NAME/libwhisper.a" \
  "ggml/src/Release-$PLATFORM_NAME/libggml-base.a" \
  "ggml/src/Release-$PLATFORM_NAME/libggml-cpu.a" \
  "ggml/src/Release-$PLATFORM_NAME/libggml.a" \
  "ggml/src/ggml-blas/Release-$PLATFORM_NAME/libggml-blas.a" \
  "ggml/src/ggml-metal/Release-$PLATFORM_NAME/libggml-metal.a"
do
  [ -f "$LIBDIR/$lib" ] || { echo "missing $lib" >&2; exit 1; }
  cp "$LIBDIR/$lib" "$OUT/$PLATFORM_NAME/"
done

for header in \
  include/whisper.h \
  ggml/include/ggml.h ggml/include/ggml-alloc.h ggml/include/ggml-backend.h \
  ggml/include/ggml-metal.h ggml/include/ggml-cpu.h ggml/include/ggml-blas.h \
  ggml/include/gguf.h
do
  cp "$SRC/$header" "$OUT/include/"
done

# The app-side seam (scripts/whisper-ios/driver/whisper_shim.c) is compiled
# here rather than in the SwiftPM target, for the same reason as ET's and
# mosh's: it includes whisper.h. The package ships whisper_shim.h alone and
# links this archive.
SDKROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
case "$SDK" in
  iphonesimulator) TARGET=arm64-apple-ios18.0-simulator ;;
  iphoneos)        TARGET=arm64-apple-ios18.0 ;;
esac
xcrun --sdk "$SDK" clang -isysroot "$SDKROOT" -target "$TARGET" -O2 -fPIC \
  -I "$OUT/include" \
  -I "$HERE/../../Packages/CQUTWhisper/Sources/CQUTWhisperC/include" \
  -c "$HERE/driver/whisper_shim.c" -o "$BUILD/whisper_shim.o"
xcrun libtool -static -o "$OUT/$PLATFORM_NAME/libwhisperclient.a" "$BUILD/whisper_shim.o" 2>/dev/null \
  || { ar rcs "$OUT/$PLATFORM_NAME/libwhisperclient.a" "$BUILD/whisper_shim.o"; }

# Same reasoning as scripts/et-ios/libsodium.sh: a configure that guessed wrong
# still emits an archive, so size is checked instead of existence. A CPU-only
# build lands near 2 MB of ggml; the Metal slice is what pushes past 5 MB, and
# its absence is exactly the mistake worth catching here.
METAL_SYMS=$(nm -gU "$OUT/$PLATFORM_NAME/libggml-metal.a" 2>/dev/null | wc -l | tr -d ' ')
[ "$METAL_SYMS" -gt 100 ] || {
  echo "libggml-metal.a has only $METAL_SYMS symbols — Metal was not built in" >&2
  exit 1
}

echo "==> vendored to $OUT"
du -sh "$OUT/$PLATFORM_NAME"/*.a | sed "s|$OUT/||"