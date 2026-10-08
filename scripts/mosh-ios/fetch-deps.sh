#!/bin/bash
#
# Fetch and cross-compile the two third-party pieces mosh's client needs.
#
#   protobuf 21.12  — the last release before protobuf took a hard dependency
#                     on abseil, which is what makes it cross-compilable
#                     without a full abseil port. Built as protobuf-lite, which
#                     is what mosh's .proto files ask for (optimize_for =
#                     LITE_RUNTIME).
#   protoc 21.12    — the generator, matching the runtime exactly. A newer
#                     protoc emits headers the older runtime rejects (unknown
#                     PROTOBUF_TSAN_DECLARE_MEMBER and friends).
#
# Usage: scripts/mosh-ios/fetch-deps.sh <workdir>
set -euo pipefail

WORK="${1:?usage: fetch-deps.sh <workdir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$WORK"
cd "$WORK"

fetch() { # url dest
  [ -f "$2" ] || curl -sSL --fail -m 300 -o "$2" "$1"
}

echo "==> sources"
fetch https://github.com/mobile-shell/mosh/releases/download/mosh-1.4.0/mosh-1.4.0.tar.gz mosh.tar.gz
fetch https://github.com/protocolbuffers/protobuf/releases/download/v21.12/protobuf-all-21.12.tar.gz protobuf.tar.gz
# protoc is a host tool, so this is the macOS build, not an iOS one.
fetch https://github.com/protocolbuffers/protobuf/releases/download/v21.12/protoc-21.12-osx-aarch_64.zip protoc.zip

[ -d mosh-1.4.0 ] || tar xzf mosh.tar.gz
[ -d protobuf-21.12 ] || tar xzf protobuf.tar.gz
[ -d protoc ] || { mkdir -p protoc && unzip -oq protoc.zip -d protoc; }

echo "==> protobuf-lite for the iOS simulator"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
cat > ios.toolchain.cmake <<EOF
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_OSX_SYSROOT "$SDK")
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET 18.0)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF

cmake -S protobuf-21.12 -B protobuf-21.12/build-ios -G "Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE="$WORK/ios.toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -Dprotobuf_BUILD_TESTS=OFF \
  -Dprotobuf_BUILD_SHARED_LIBS=OFF \
  -Dprotobuf_WITH_ZLIB=OFF >/dev/null
cmake --build protobuf-21.12/build-ios --target libprotobuf-lite -j4 >/dev/null

echo "==> protobuf-lite built: $WORK/protobuf-21.12/build-ios/libprotobuf-lite.a"
echo "==> now run: $HERE/build.sh $WORK/mosh-1.4.0 $WORK/out"