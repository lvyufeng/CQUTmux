#!/bin/bash
#
# The check that matters for on-device speech: a real recording, through the
# vendored parakeet.cpp, on a simulator, coming back as the words that were
# said.
#
# Linking proves nothing: a mismatched ggml, a C API wired to the wrong decoder
# head, or an unapplied conv-2d patch all produce a binary that loads a GGUF
# happily and then emits nonsense. So this asserts the words.
#
# It also settles the thing that decides whether this engine can ship at all.
# This app already links whisper.cpp with its own static ggml, and parakeet.cpp
# carries a *different*, patched ggml. Two static archives contributing the same
# symbols is not a link error — the second one is simply ignored, and whichever
# engine lost binds to the other's ggml. The check runs parakeet against its own
# ggml so the words are meaningful, and scripts/parakeet-ios/README.md records
# what that means for linking both into one app.
#
# Usage: scripts/parakeet-ios/check.sh <vendored-dir> <model.gguf> <audio.wav> [device-udid]
set -euo pipefail

VENDOR="${1:?usage: check.sh <vendored-dir> <model.gguf> <audio.wav> [device-udid]}"
MODEL="${2:?usage: check.sh <vendored-dir> <model.gguf> <audio.wav> [device-udid]}"
WAV="${3:?usage: check.sh <vendored-dir> <model.gguf> <audio.wav> [device-udid]}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DEVICE="${4:-$(xcrun simctl list devices booted -j | python3 -c \
  "import json,sys; d=json.load(sys.stdin)['devices']; print([x['udid'] for v in d.values() for x in v if x['state']=='Booted'][0])")}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET=arm64-apple-ios18.0-simulator
LIBS="$VENDOR/iphonesimulator"

echo "==> building the check for the simulator"
# Linked with clang++ rather than clang: parakeet.cpp is C++ and its archives
# reference the C++ runtime, which clang will not pull in on its own.
xcrun --sdk iphonesimulator clang++ -isysroot "$SDK" -target "$TARGET" -O1 \
  -I"$VENDOR/include" \
  "$HERE/driver/transcribe.c" \
  "$LIBS/libparakeet.a" \
  "$LIBS/libggml.a" \
  "$LIBS/libggml-base.a" \
  "$LIBS/libggml-cpu.a" \
  "$LIBS/libggml-metal.a" \
  "$LIBS/libggml-blas.a" \
  -framework Accelerate -framework Metal -framework MetalKit \
  -framework Foundation \
  -o "$WORK/transcribe"

# simctl spawn runs the program inside the simulator's own filesystem, so both
# the binary and the files it opens are staged in there — a host path is not
# mapped and dyld aborts before main().
SIMTMP="$(xcrun simctl getenv "$DEVICE" HOME 2>/dev/null)/tmp"
[ -d "$SIMTMP" ] || { echo "simulator $DEVICE has no $SIMTMP" >&2; exit 1; }
cp "$WORK/transcribe" "$SIMTMP/"
cp "$MODEL" "$SIMTMP/parakeet.gguf"
cp "$WAV" "$SIMTMP/parakeet.wav"

echo "==> transcribing (the model loads once, so this takes a few seconds)"
# The words the upstream project publishes for its own fixture. Asserting on
# them rather than on "a transcript came back" is the difference between
# testing the model and testing that a file was written.
# PARAKEET_DEVICE=cpu, for the reason scripts/whisper-ios/README.md records: the
# simulator's GPU reports recommendedMaxWorkingSetSize 0.00 MB and traps in the
# Metal backend. The same source passes with the GPU on real hardware, so this
# is a limit of the simulator rather than of the engine.
set +e
# simctl has no way to pass environment positionally; the SIMCTL_CHILD_ prefix
# on the host variable is how it reaches the spawned process.
OUT="$(SIMCTL_CHILD_PARAKEET_DEVICE=cpu xcrun simctl spawn "$DEVICE" \
  "$SIMTMP/transcribe" "$SIMTMP/parakeet.gguf" "$SIMTMP/parakeet.wav" "Phoebe" "portrait" 2>&1)"
STATUS=$?
set -e
echo "$OUT"

xcrun simctl spawn "$DEVICE" rm -f "$SIMTMP/transcribe" "$SIMTMP/parakeet.gguf" "$SIMTMP/parakeet.wav" 2>/dev/null || true

if [ "$STATUS" -ne 0 ]; then
  echo "parakeet check FAILED (exit $STATUS)" >&2
  exit 1
fi
echo "parakeet check passed"