#!/bin/bash
#
# Build Eternal Terminal's client core for iOS.
#
# The finding that made this possible: ET is not bound to a local pty. It has a
# Console interface (src/terminal/Console.hpp) that exists precisely so a non-pty
# front end can drive TerminalClient, and the forkpty code lives behind it in
# PseudoUserTerminalUnix. So the same shape of work mosh needed applies — supply
# the front end, keep the protocol.
#
# Getting it to compile for iOS needed three things:
#
#   1. libsodium, whose iOS build is scripts/et-ios/libsodium.sh.
#   2. Not using OpenSSL. ET's Headers.hpp enables httplib's OpenSSL support
#      unconditionally; iOS has no OpenSSL. That support is only for the
#      telemetry client, which is compiled out here (NO_TELEMETRY).
#   3. Turning off the pieces that assume a desktop process: the daemon/pty
#      path, and the mux/control machinery that is all local-socket based.
#
# Usage: scripts/et-ios/build.sh <et-source-dir> <libsodium-dir> <out-dir> [simulator|device]
set -euo pipefail

ET="${1:?usage: build.sh <et-source-dir> <libsodium-dir> <out-dir> [simulator|device]}"
SODIUM="${2:?usage: build.sh <et-source-dir> <libsodium-dir> <out-dir> [simulator|device]}"
OUT="${3:?usage: build.sh <et-source-dir> <libsodium-dir> <out-dir> [simulator|device]}"
PLATFORM="${4:-simulator}"
HERE="$(cd "$(dirname "$0")" && pwd)"

case "$PLATFORM" in
  simulator) SDK=iphonesimulator; TARGET=arm64-apple-ios18.0-simulator ;;
  device)    SDK=iphoneos;        TARGET=arm64-apple-ios18.0 ;;
  *) echo "unknown platform '$PLATFORM'" >&2; exit 2 ;;
esac

PROTOBUF_SRC="${PROTOBUF_SRC:-$(dirname "$ET")/protobuf-21.12/src}"
PROTOC="${PROTOC:-$(dirname "$ET")/protoc/bin/protoc}"
SDKROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"

rm -rf "$OUT"
mkdir -p "$OUT/obj" "$OUT/pb"

echo "==> generating ET's protobuf sources"
for proto in ETerminal ET; do
  "$PROTOC" --proto_path="$ET/proto" --cpp_out="$OUT/pb" "$ET/proto/$proto.proto"
done

INCLUDES=(
  -I"$ET/src/base" -I"$ET/src/terminal" -I"$ET/src/terminal/forwarding" -I"$ET/src/htm"
  -I"$ET/external" -I"$ET/external/easyloggingpp/src" -I"$ET/external/json/single_include"
  -I"$ET/external/PlatformFolders" -I"$ET/external/msgpack-c/include" -I"$ET/external/simpleini"
  -I"$ET/external/cpp-httplib" -I"$ET/external/cxxopts/include" -I"$ET/external/sole"
  -I"$ET/external/base64" -I"$ET/external/UniversalStacktrace/ust" -I"$ET/external/ThreadPool"
  -I"$SODIUM/include" -I"$OUT/pb" -I"$PROTOBUF_SRC"
)

# NO_TELEMETRY: drops the Sentry/httplib client, which is the only thing
# wanting OpenSSL. ET_HAS_IOS marks the handful of places that have to differ
# on a platform with no fork/exec and no /tmp of its own.
CXXFLAGS=(
  -isysroot "$SDKROOT" -target "$TARGET" -std=c++17 -O2 -fPIC
  -DNO_TELEMETRY -DET_IOS=1
  -Wno-deprecated-declarations -Wno-unused-parameter
  -Wno-error
  "${INCLUDES[@]}"
)

# The client core. Everything on the local-socket side (the mux, the control
# channel, the session store that reads a config dir) is deliberately absent:
# it exists to attach ET clients to each other on one machine, which is not
# something an iPhone does.
#
# The Windows/Linux-only platform sources are excluded by construction — this
# list names the Unix ones.
SOURCES=(
  src/base/BackedReader.cpp src/base/BackedWriter.cpp src/base/ClientConnection.cpp
  src/base/Connection.cpp src/base/CryptoHandler.cpp src/base/FdPoller.cpp
  src/base/ServerClientConnection.cpp src/base/ServerConnection.cpp
  src/base/SocketHandler.cpp src/base/PipeSocketHandler.cpp src/base/PollSet.cpp
  src/base/TcpSocketHandler.cpp src/base/UnixSocketHandler.cpp src/base/LogHandler.cpp
  src/base/RawSocketUtils.cpp src/base/TunnelUtils.cpp src/base/SocksUtils.cpp
  src/base/DaemonCreatorUnix.cpp src/base/PipeSocketHandlerUnix.cpp
  src/base/PlatformUtilsUnix.cpp src/base/RawSocketUtilsUnix.cpp
  src/base/UnixSocketHandlerUnix.cpp src/base/TcpSocketHandlerUnix.cpp
  src/base/PollSetUnix.cpp src/base/SubprocessUtilsUnix.cpp src/base/UserSocketOpsUnix.cpp
  src/terminal/TerminalClient.cpp src/terminal/TitleParser.cpp
  # The forwarding handlers are required even though the app never opens a
  # tunnel: TerminalClient.cpp calls hasActiveStdioForward() on the handler
  # unconditionally, and that pulls in the whole PortForwardHandler, which
  # pulls in both of these. Leaving them out is an undefined symbol at link,
  # not a dead branch.
  src/terminal/forwarding/PortForwardHandler.cpp
  src/terminal/forwarding/ForwardSourceHandler.cpp
  src/terminal/forwarding/ForwardDestinationHandler.cpp
  # Console declares virtuals and defines only some of them inline, so its
  # vtable — and therefore the typeinfo any Console subclass needs — is emitted
  # here. Without this object the driver's own class fails to link, with an
  # error that points at the subclass rather than at the missing base.
  src/terminal/ConsoleUnix.cpp
)

echo "==> compiling ET client core"
i=0
for src in "${SOURCES[@]}"; do
  [ -f "$ET/$src" ] || { echo "    missing: $src (ET's tree moved — update this list)" >&2; exit 1; }
  obj="$OUT/obj/$(echo "$src" | tr '/' '_').o"
  echo "    $(basename "$src")"
  xcrun --sdk "$SDK" clang++ "${CXXFLAGS[@]}" -c "$ET/$src" -o "$obj"
  i=$((i + 1))
done

echo "==> compiling vendored and generated sources"
for src in "$ET/external/easyloggingpp/src/easylogging++.cc" \
           "$ET/external/PlatformFolders/sago/platform_folders.cpp" \
           "$OUT"/pb/*.pb.cc; do
  obj="$OUT/obj/ext_$(basename "$src").o"
  echo "    $(basename "$src")"
  xcrun --sdk "$SDK" clang++ "${CXXFLAGS[@]}" -c "$src" -o "$obj"
done

echo "==> compiling the CQUT ET driver"
# It needs ET's headers, so it is built here rather than as a SwiftPM target —
# SwiftPM cannot see this tree, the same reason mosh's driver lives here.
# -fvisibility=default: the class-info symbols the driver's vtable needs are
# typeinfo for ET's own classes, which -fvisibility-inlines-hidden can leave
# undefined. Nothing else in this archive is loaded dynamically, so the flag
# costs nothing here.
xcrun --sdk "$SDK" clang++ "${CXXFLAGS[@]}" -fvisibility=default \
  -c "$HERE/driver/et_driver.cc" -o "$OUT/obj/cqutet_driver.o"
# TelemetryService is compiled out by NO_TELEMETRY but still referenced by
# TerminalClient, so its two symbols are supplied from the driver directory.
xcrun --sdk "$SDK" clang++ "${CXXFLAGS[@]}" \
  -c "$HERE/driver/telemetry_stub.cc" -o "$OUT/obj/cqutet_telemetry.o"

echo "==> archiving"
xcrun --sdk "$SDK" libtool -static -o "$OUT/libetcore.a" "$OUT"/obj/*.o
echo "==> done: $OUT/libetcore.a ($i sources)"
nm -g "$OUT/libetcore.a" 2>/dev/null | grep -cE " T __ZN2et" || true
nm -g "$OUT/libetcore.a" 2>/dev/null | grep -c " T _et_start" || true