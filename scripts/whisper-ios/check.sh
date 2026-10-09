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

echo "==> building the check for the simulator"
LIBS="$VENDOR/iphonesimulator"
xcrun --sdk iphonesimulator clang -isysroot "$SDK" -target "$TARGET" -O1 \
  -I"$VENDOR/include" \
  "$HERE/checks/transcribe.c" \
  "$LIBS/libwhisper.a" \
  "$LIBS/libggml.a" \
  "$LIBS/libggml-base.a" \
  "$LIBS/libggml-cpu.a" \
  "$LIBS/libggml-metal.a" \
  "$LIBS/libggml-blas.a" \
  -lc++ -framework Accelerate -framework Metal -framework MetalKit \
  -framework Foundation -framework CoreML \
  -o "$WORK/transcribe"

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
cp "$WORK/transcribe" "$SIMTMP/"
mkdir -p "$SIMTMP/speech"
[ -n "$DEST" ] && cp "$MODEL" "$WAV" "$DEST/" && mkdir -p "$DEST/speech"

echo "==> transcribing $(basename "$WAV") with $(basename "$MODEL")"
xcrun simctl spawn "$DEVICE" "$SIMTMP/transcribe" "$SIMTMP/$(basename "$MODEL")" "$SIMTMP/$(basename "$WAV")" \
  | tee "$WORK/out"

grep -q WHISPER_CHECK_PASS "$WORK/out" \
  && echo "==> PASS: backend registered, model loaded, speech recognised" \
  || { echo "==> FAIL"; exit 1; }