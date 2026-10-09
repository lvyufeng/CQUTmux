#!/bin/bash
#
# Build parakeet.cpp's speech-to-text core for iOS.
#
# Same shape as scripts/whisper-ios/build.sh, and for the same two reasons:
# upstream wants to build a dynamic framework for four platforms, and we link
# static archives so nothing has to be embedded or re-signed. The difference
# worth noting is that parakeet.cpp carries its own patched ggml in
# third_party/ rather than taking ggml as a dependency, so the two engines do
# not share a ggml and each vendor directory has to be complete on its own.
#
# Note the Metal switch is PARAKEET_GGML_METAL, not GGML_METAL: parakeet.cpp
# FORCEs the ggml option from its own variable, so setting GGML_METAL directly
# is silently overwritten and the build comes out CPU-only with no complaint.
#
# Parakeet is the engine Moshi's docs recommend for English, and the reason is
# the size: 110M parameters against whisper's smallest useful model, at a word
# error rate the project measures as byte-identical to NeMo's reference. That is
# the difference between a dictation that feels immediate and one that makes the
# user wait — which is the whole claim on-device speech makes.
#
# cmake is not on PATH on this machine; it is available as `python3 -m cmake`,
# and PATH=${HOME}/.local/bin:$PATH is assumed.
#
# Usage: scripts/parakeet-ios/build.sh <parakeet-source-dir> <out-dir> [simulator|device]
set -euo pipefail

SRC="${1:?usage: build.sh <parakeet-source-dir> <out-dir> [simulator|device]}"
OUT="${2:?usage: build.sh <parakeet-source-dir> <out-dir> [simulator|device]}"
PLATFORM="${3:-simulator}"

case "$PLATFORM" in
  simulator) SDK=iphonesimulator; ARCHS="arm64"; PLATFORM_NAME=iphonesimulator ;;
  device)    SDK=iphoneos;        ARCHS="arm64"; PLATFORM_NAME=iphoneos ;;
  *) echo "unknown platform '$PLATFORM'" >&2; exit 2 ;;
esac

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

echo "==> configuring parakeet.cpp for $PLATFORM"
cmake -B "$BUILD/build" -G Xcode \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$SDK" \
  -DCMAKE_OSX_ARCHITECTURES="$ARCHS" \
  -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS="$PLATFORM_NAME" \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="" \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
  -DBUILD_SHARED_LIBS=OFF \
  -DPARAKEET_BUILD_CLI=OFF \
  -DPARAKEET_BUILD_TESTS=OFF \
  -DPARAKEET_GGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_BLAS_DEFAULT=ON \
  -DGGML_METAL_USE_BF16=ON \
  -DGGML_OPENMP=OFF \
  -DGGML_NATIVE=OFF \
  "$SRC"

echo "==> building (this takes a few minutes)"
cmake --build "$BUILD/build" --config Release -- \
  -destination "generic/platform=$PLATFORM_NAME" \
  -skipPackagePluginValidation \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# The archives are collected by pattern rather than by name because parakeet.cpp
# and ggml between them emit a set that moves with the version, and a
# hard-coded list is a build that breaks on upgrade for no interesting reason.
mkdir -p "$OUT/include" "$OUT/$PLATFORM_NAME"
found=0
for lib in $(find "$BUILD/build" -name 'lib*.a' -path "*Release-$PLATFORM_NAME/*" -o -name 'lib*.a' -path "*Release/*" | sort -u); do
  cp "$lib" "$OUT/$PLATFORM_NAME/"
  found=$((found + 1))
done
echo "==> collected $found archives"

if [ "$found" -eq 0 ]; then
  echo "no archives were produced — the build silently did nothing, which is worse" >&2
  echo "than failing, because the app would then link against nothing" >&2
  exit 1
fi

cp "$SRC/include/parakeet_capi.h" "$OUT/include/"

# Same reasoning as scripts/whisper-ios/build.sh: a configure that guessed
# wrong still emits an archive, so the symbol count is what stands in for
# "the backend is really in there". Counted over all symbols rather than
# filtered by name, because the C++ mangling here buries the ggml_backend_metal
# prefix inside longer names and a name filter undercounts. A CPU-only build
# lands near 60; this one is 276.
METAL_SYMS=$(nm -gU "$OUT/$PLATFORM_NAME/libggml-metal.a" 2>/dev/null | wc -l | tr -d ' ')
[ "$METAL_SYMS" -gt 100 ] || {
  echo "libggml-metal.a has only $METAL_SYMS symbols — Metal was not built in" >&2
  exit 1
}
echo "==> Metal backend present ($METAL_SYMS symbols)"

echo "==> wrote $OUT"
ls -la "$OUT/$PLATFORM_NAME"