#!/bin/bash
#
# Build ET's host binaries (etserver / etterminal) so the iOS client can be
# tested against a real server.
#
# ET publishes no macOS release asset — its GitHub releases carry a
# windows-x64.zip, an arm64.deb and the source tarball, nothing for Darwin — so
# the server side has to be built here. Three things get in the way, and each
# has a specific answer:
#
#   1. Protobuf. ET's CMake wants a *host* libprotobuf. Nothing on this machine
#      has one, and the protobuf built for iOS is arm64-iOS, which cannot link
#      into a macOS executable. It is built natively from the same source tree
#      (protobuf is arch-agnostic in its own build).
#
#   2. OpenSSL. ET's CMakeLists calls find_package(OpenSSL REQUIRED) even though
#      OpenSSL is only reachable from the telemetry path, which -DDISABLE_TELEMETRY
#      compiles out. The Xcode macOS SDK ships no openssl/ headers. Building
#      OpenSSL from source to satisfy a dependency nothing uses is not worth it
#      when a copy already exists: the one in conda is a real OpenSSL 3.x with
#      headers.
#
#   3. sanitizers-cmake. A git submodule that ET's CMake requires and that a
#      plain tarball checkout does not contain.
#
#   4. Two more that only surface once the first three are past, and that are
#      worth knowing before chasing them:
#        - ET's Headers.hpp defines CPPHTTPLIB_OPENSSL_SUPPORT for every
#          platform. It is load-bearing on macOS: httplib's Client constructor
#          *throws* on an https:// URL when compiled without a TLS backend, and
#          TelemetryService constructs one with a hardcoded https:// URL before
#          its NO_TELEMETRY check can return — so etserver dies at startup and
#          never listens. The iOS patch must therefore be iOS-scoped.
#        - Once httplib is built with TLS it wants CoreFoundation and Security
#          on macOS (keychain root certificates), which ET's CMake does not add.
#
# Usage: scripts/et-ios/host-tools.sh <et-source-dir> <out-dir>
set -euo pipefail

ET="${1:?usage: host-tools.sh <et-source-dir> <out-dir>}"
OUT="${2:?usage: host-tools.sh <et-source-dir> <out-dir>}"

# cmake and protoc are not on PATH here; the ones this machine has live in the
# user-site Python bin.
export PATH="$(python3 -c 'import site,sys; print(site.getusersitepackages())' 2>/dev/null | sed 's|/lib/python[^/]*/site-packages|/bin|'):$PATH"
command -v cmake >/dev/null || { echo "cmake not found (pip install cmake)"; exit 1; }

OPENSSL_PREFIX="$(dirname "$(dirname "$(command -v python3 2>/dev/null || echo /usr/bin/python3)")")"
if [ ! -f "$OPENSSL_PREFIX/include/openssl/ssl.h" ]; then
  for candidate in /opt/homebrew/opt/openssl /usr/local/opt/openssl; do
    [ -f "$candidate/include/openssl/ssl.h" ] && OPENSSL_PREFIX="$candidate" && break
  done
fi
[ -f "$OPENSSL_PREFIX/include/openssl/ssl.h" ] || {
  echo "no OpenSSL headers found; set OPENSSL_PREFIX" >&2; exit 1; }
echo "==> OpenSSL: $OPENSSL_PREFIX"

PROTO_SRC="${PROTOBUF_SRC:-$(dirname "$ET")/protobuf-21.12}"
mkdir -p "$OUT" "$OUT/protobuf" "$OUT/et"

# --- protobuf, native -------------------------------------------------------
if [ ! -f "$OUT/protobuf/libprotobuf.a" ]; then
  echo "==> building native protobuf"
  # The source tree protoc lives beside is the same one mosh's iOS build used.
  (cd "$OUT/protobuf" && cmake "$PROTO_SRC/cmake" \
      -DCMAKE_BUILD_TYPE=Release \
      -Dprotobuf_BUILD_TESTS=OFF \
      -Dprotobuf_BUILD_CONFORMANCE=OFF \
      -Dprotobuf_BUILD_EXAMPLES=OFF \
      -DCMAKE_POLICY_DEFAULT_CMP0111=NEW >configure.log 2>&1) \
    || { echo "protobuf configure failed; see $OUT/protobuf/configure.log"; exit 1; }
  (cd "$OUT/protobuf" && cmake --build . -j"$(sysctl -n hw.ncpu)" >build.log 2>&1) \
    || { echo "protobuf build failed; see $OUT/protobuf/build.log"; exit 1; }
fi
[ -f "$OUT/protobuf/libprotobuf.a" ] || { echo "no libprotobuf.a"; exit 1; }

# --- sanitizers-cmake, a submodule ------------------------------------------
if [ ! -f "$ET/external/sanitizers-cmake/CMakeLists.txt" ]; then
  echo "==> fetching the sanitizers-cmake submodule"
  (cd "$ET" && git submodule update --init --depth 1 external/sanitizers-cmake)
fi

# --- libsodium + OpenSSL, native --------------------------------------------
SODIUM_PREFIX="${SODIUM_PREFIX:-}"
if [ -z "$SODIUM_PREFIX" ]; then
  # Whatever et-ios/libsodium.sh produced for iOS is arm64-iOS and cannot link
  # here. libsodium's tarball configure takes a minute natively, so it is worth
  # doing rather than depending on an installed copy that may not exist.
  for candidate in /opt/homebrew /usr/local /tmp/et-host; do
    if [ -f "$candidate/include/sodium.h" ] && [ -f "$candidate/lib/libsodium.a" ]; then
      SODIUM_PREFIX="$candidate"; break
    fi
  done
fi
[ -n "$SODIUM_PREFIX" ] || { echo "no native libsodium; set SODIUM_PREFIX"; exit 1; }
echo "==> libsodium: $SODIUM_PREFIX"

# --- ET ---------------------------------------------------------------------
echo "==> configuring ET"
(cd "$OUT/et" && cmake "$ET" \
    -DCMAKE_BUILD_TYPE=Release \
    -DDISABLE_VCPKG=ON -DBUILD_TESTING=OFF \
    -DDISABLE_SENTRY=ON -DDISABLE_TELEMETRY=ON -DDISABLE_CRASH_LOG=ON \
    -DCMAKE_PREFIX_PATH="$SODIUM_PREFIX" \
    -Dsodium_INCLUDE_DIR="$SODIUM_PREFIX/include" \
    -Dsodium_LIBRARY_RELEASE="$SODIUM_PREFIX/lib/libsodium.a" \
    -DProtobuf_INCLUDE_DIR="$PROTO_SRC/src" \
    -DProtobuf_LIBRARY="$OUT/protobuf/libprotobuf.a" \
    -DPROTOBUF_PROTOC_EXECUTABLE="$OUT/protobuf/protoc" \
    -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX" \
    -DOPENSSL_INCLUDE_DIR="$OPENSSL_PREFIX/include" \
    -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_PREFIX/lib/libcrypto.dylib" \
    -DOPENSSL_SSL_LIBRARY="$OPENSSL_PREFIX/lib/libssl.dylib" \
    -DCMAKE_EXE_LINKER_FLAGS="-framework CoreFoundation -framework Security" \
    >configure.log 2>&1) \
  || { echo "ET configure failed; see $OUT/et/configure.log"; tail -30 "$OUT/et/configure.log"; exit 1; }

echo "==> building etserver and etterminal"
(cd "$OUT/et" && cmake --build . --target etserver etterminal -j"$(sysctl -n hw.ncpu)" >build.log 2>&1) \
  || { echo "ET build failed; see $OUT/et/build.log"; tail -30 "$OUT/et/build.log"; exit 1; }

echo "==> done"
echo "    $OUT/et/etserver"
echo "    $OUT/et/etterminal"