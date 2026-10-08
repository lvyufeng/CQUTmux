#!/bin/bash
#
# Cross-compile libsodium for iOS.
#
# Eternal Terminal's handshake is built on libsodium (secretbox/box), and
# libsodium is the one dependency of ET's that is genuinely awkward to
# cross-compile — it is autoconf-based, and it decides at build time which
# primitives exist by *running* test programs. Those cannot run for a
# different platform, so the configure cache has to be given the answers.
#
# libsodium ships its own cache file for iOS; without it configure either
# fails or silently builds a stub library. Everything else (zlib, libc++) is
# already on iOS.
#
# Usage: scripts/et-ios/libsodium.sh <libsodium-source-dir> <out-dir> [simulator|device]
set -euo pipefail

SRC="${1:?usage: libsodium.sh <libsodium-source-dir> <out-dir> [simulator|device]}"
OUT="${2:?usage: libsodium.sh <libsodium-source-dir> <out-dir> [simulator|device]}"
PLATFORM="${3:-simulator}"
HERE="$(cd "$(dirname "$0")" && pwd)"

case "$PLATFORM" in
  simulator) SDK=iphonesimulator; TARGET=arm64-apple-ios18.0-simulator ;;
  device)    SDK=iphoneos;        TARGET=arm64-apple-ios18.0 ;;
  *) echo "unknown platform '$PLATFORM'" >&2; exit 2 ;;
esac

mkdir -p "$OUT" "$HERE/tools"
CC="$HERE/tools/cc-$PLATFORM"
CXX="$HERE/tools/cxx-$PLATFORM"
cat > "$CC" <<EOF
#!/bin/sh
exec xcrun --sdk $SDK clang -target $TARGET "\$@"
EOF
cat > "$CXX" <<EOF
#!/bin/sh
exec xcrun --sdk $SDK clang++ -target $TARGET -std=c++17 "\$@"
EOF
chmod +x "$CC" "$CXX"

# `--host` has to be a triple libsodium's config.sub understands. The iOS
# kernel names ("ios18.0", "simulator") are not, so it is told "darwin" and the
# real target comes from the compiler wrapper above — libsodium only uses the
# host triple to pick which of its assembly implementations to assemble.
cd "$SRC"
make distclean >/dev/null 2>&1 || true
./configure \
  --host=aarch64-apple-darwin \
  --enable-minimal \
  --disable-shared --enable-static \
  CC="$CC" CXX="$CXX" \
  >"$OUT/configure.log" 2>&1

make -j"$(sysctl -n hw.ncpu)" >"$OUT/build.log" 2>&1

mkdir -p "$OUT/lib" "$OUT/include"
cp src/libsodium/.libs/libsodium.a "$OUT/lib/"
cp -R src/libsodium/include/* "$OUT/include/"

echo "==> $OUT/lib/libsodium.a"
# The proof this is not a stub: --enable-minimal keeps secretbox, which is what
# ET's handshake uses. A configure that fell back to "no" on everything still
# produces an archive, so counting the symbols is the check that matters.
count=$(xcrun --sdk "$SDK" nm -g "$OUT/lib/libsodium.a" 2>/dev/null \
  | grep -c "crypto_secretbox_xsalsa20poly1305" || true)
echo "    secretbox symbols: $count"
[ "$count" -gt 0 ] || { echo "libsodium built without secretbox — configure guessed wrong"; exit 1; }