#!/bin/bash
#
# The check that matters for on-device speech: a real recording, through the
# vendored whisper.cpp, on a simulator, coming back as the words that were said.
#
# Linking this proves nothing on its own. A backend that configured but never
# registered, or a Metal library that built but was not embedded, still links,
# still loads a model, and still returns a transcript — just not the right one,
# or not fast enough to be worth having. So this asserts the speech.
#
# Needs a model, which is not vendored (77 MB for the smallest English one, and
# then only usable for English). Fetch it with the download script below. The
# same path is what the app uses at runtime, so a failure here is a failure
# there.
#
# Usage: scripts/whisper-ios/check.sh <vendored-dir> <model.bin> [device-udid]
set -euo pipefail

VENDOR="${1:?usage: check.sh <vendored-dir> <model.bin> [device-udid]}"
MODEL="${2:?usage: check.sh <vendored-dir> <model.bin> [device-udid]}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DEVICE="${3:-$(xcrun simctl list devices booted -j | python3 -c \
  "import json,sys; d=json.load(sys.stdin)['devices']; print([x['udid'] for v in d.values() for x in v if x['state']=='Booted'][0])")}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET=arm64-apple-ios18.0-simulator

# Which engine to exercise. The harness around it is identical — same vendored
# tree, same single ggml, same simulator staging — so only the driver, the
# archive it links, and the marker differ.
ENGINE="${CQUT_ENGINE:-whisper}"

echo "==> building the $ENGINE check for the simulator"
LIBS="$VENDOR/iphonesimulator"
# Both paths link the one ggml, which is the point: whisper.cpp 1.9.5 builds
# Parakeet in-tree against the same ggml, so no second copy is ever introduced.
GGML_LIBS="$LIBS/libggml.a $LIBS/libggml-base.a $LIBS/libggml-cpu.a $LIBS/libggml-metal.a $LIBS/libggml-blas.a"
if [ "$ENGINE" = "parakeet" ]; then
  # Goes through libwhisperclient.a because it drives the app's own seam
  # (cqut_parakeet_*), not parakeet.h. The CLI can call parakeet_full directly;
  # the app cannot, and the seam is what needs testing.
  xcrun --sdk iphonesimulator clang -isysroot "$SDK" -target "$TARGET" -O1 \
    -I"$VENDOR/include" \
    -I"$HERE/../../Packages/CQUTWhisper/Sources/CQUTWhisperC/include" \
    "$HERE/checks/parakeet.c" \
    "$LIBS/libwhisperclient.a" "$LIBS/libparakeet.a" $GGML_LIBS \
    -lc++ -framework Accelerate -framework Metal -framework MetalKit \
    -framework Foundation -framework CoreML \
    -o "$WORK/parakeet-check" || { echo "check failed to build" >&2; exit 1; }
else
  xcrun --sdk iphonesimulator clang -isysroot "$SDK" -target "$TARGET" -O1 \
    -I"$VENDOR/include" \
    "$HERE/checks/transcribe.c" \
    "$LIBS/libwhisper.a" $GGML_LIBS \
    -lc++ -framework Accelerate -framework Metal -framework MetalKit \
    -framework Foundation -framework CoreML \
    -o "$WORK/transcribe" || { echo "check failed to build" >&2; exit 1; }
fi

# simctl spawn runs the program inside the simulator's own filesystem. A host
# temp path is not mapped in there, and dyld aborts on the executable before
# main() ever runs, so the binary is staged next to the model rather than
# pointed at from the host.
SIMTMP="$(xcrun simctl getenv "$DEVICE" HOME 2>/dev/null)/tmp"
[ -d "$SIMTMP" ] || { echo "simulator $DEVICE has no $SIMTMP" >&2; exit 1; }

# The 16 kHz mono sample the upstream README uses. Copied into the container
# rather than passed as a host path: simctl spawn runs inside the simulator's
# filesystem, and a /tmp path on the host does not exist in there.
WAV="${WHISPER_SAMPLE:-/tmp/whisper-src/samples/jfk.wav}"
[ -f "$WAV" ] || { echo "no sample at $WAV" >&2; exit 1; }

CONTAINER="$(xcrun simctl get_app_container "$DEVICE" app.cqutmux.ios data 2>/dev/null || true)"
DEST="${CONTAINER:+$CONTAINER/Documents}"
[ -n "$DEST" ] && mkdir -p "$DEST"

cp "$MODEL" "$WAV" "$SIMTMP/"
# Stage whichever binary this mode built. Resolved here rather than in the
# engine block below because staging happens before it.
if [ "$ENGINE" = "parakeet" ]; then cp "$WORK/parakeet-check" "$SIMTMP/"; else cp "$WORK/transcribe" "$SIMTMP/"; fi
mkdir -p "$SIMTMP/speech"
[ -n "$DEST" ] && cp "$MODEL" "$WAV" "$DEST/" && mkdir -p "$DEST/speech"

# CQUT_ENGINE=parakeet runs the same harness against the other engine, because
# everything either side of the link line is identical: same vendored tree, same
# one ggml, same simulator staging. Only the driver and the marker differ, and
# the marker is what proves the right one actually ran.
if [ "$ENGINE" = "parakeet" ]; then
  EXPECT="PARAKEET_CHECK_PASS"
  BINARY="$WORK/parakeet-check"
else
  EXPECT="WHISPER_CHECK_PASS"
  BINARY="$WORK/transcribe"
fi

echo "==> transcribing $(basename "$WAV") with $(basename "$MODEL") via $ENGINE"
# WHISPER_NO_GPU is forwarded explicitly: simctl has no positional environment,
# and a host variable reaches the spawned process only under the SIMCTL_CHILD_
# prefix. Set without it — as this script first did — the simulator uses its stub
# GPU, reports working-set 0, and traps inside Metal, which reads as the engine
# being broken rather than the invocation being wrong.
SIMCTL_CHILD_WHISPER_NO_GPU="${WHISPER_NO_GPU:-}" \
xcrun simctl spawn "$DEVICE" "$SIMTMP/$(basename "$BINARY")" "$SIMTMP/$(basename "$MODEL")" "$SIMTMP/$(basename "$WAV")" \
  ${CQUT_EXPECT:+"$CQUT_EXPECT"} | tee "$WORK/out"

grep -q "$EXPECT" "$WORK/out" \
  && echo "==> PASS: $ENGINE registered, model loaded, speech recognised" \
  || { echo "==> FAIL"; exit 1; }