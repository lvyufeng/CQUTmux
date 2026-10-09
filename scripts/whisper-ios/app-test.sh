#!/usr/bin/env bash
#
# Runs a real recording through the app's own on-device speech path and checks
# that the words come back.
#
# What this covers that scripts/whisper-ios/check.sh does not
# ----------------------------------------------------------
# That check links the vendored archives directly and proves the codec works.
# This one goes through the shipped app: the model catalog and its path in the
# app container, the SwiftPM C seam, `WhisperDictation`'s decoding and model
# load, and the terminal's own status line. A model that loads in a test harness
# and not in the app is a real failure mode — a missing header, a link flag that
# only the app target was missing, a GPU flag that only the app sets.
#
# The microphone is the one thing a simulator cannot drive, so the audio is
# supplied as a file. Everything downstream of capture is the real path; the
# debug hook calls the same `transcribeFile` a future "transcribe this
# recording" feature would.
#
# CQUT_ENGINE picks which engine the app should use; the prefs key differs by
# family, because the two choices are stored separately.
#
# Usage: scripts/whisper-ios/app-test.sh [model.bin] [wav]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

DEVICE="${DEVICE:-iPhone 17}"
MODEL="${1:-/tmp/ggml-tiny.en.bin}"
WAV="${2:-/tmp/whisper-src/samples/jfk.wav}"
SHOT="${SHOT:-/tmp/cqutmux_whisper.png}"

UDID="$(xcrun simctl list devices available | grep -m1 "$DEVICE (" | grep -oE '[0-9A-F-]{36}')"
[[ -n "$UDID" ]] || { echo "simulator '$DEVICE' not found" >&2; exit 1; }
APP="build/Build/Products/Debug-iphonesimulator/CQUTmux.app"
[[ -d "$APP" ]] || { echo "no app — build first (scripts/build.sh)" >&2; exit 1; }
[[ -f "$MODEL" ]] || { echo "no model at $MODEL — see scripts/whisper-ios/model.sh" >&2; exit 1; }
[[ -f "$WAV" ]] || { echo "no audio at $WAV" >&2; exit 1; }

echo "==> installing fresh"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl terminate "$UDID" app.cqutmux.ios 2>/dev/null || true
xcrun simctl uninstall "$UDID" app.cqutmux.ios 2>/dev/null || true
xcrun simctl spawn "$UDID" launchctl kickstart -k system/com.apple.SpringBoard 2>/dev/null || true
sleep 3
xcrun simctl install "$UDID" "$APP"

# The model goes where `WhisperModelStore` looks, which is the app's own
# Application Support directory — not Documents, and not /tmp, because the
# point is to exercise the path the app uses.
CONTAINER="$(xcrun simctl get_app_container "$UDID" app.cqutmux.ios data)"
DEST="$CONTAINER/Library/Application Support/Whisper"
mkdir -p "$DEST"
# The name matters, not just the bytes: `WhisperModelStore.isInstalled` matches
# on the exact file name from the catalog, so a model fetched by hand under a
# different name is invisible to the app. CQUT_MODEL_NAME overrides for a file
# whose local name does not match its catalog entry.
MODEL_NAME="${CQUT_MODEL_NAME:-$(basename "$MODEL")}"
echo "==> staging $MODEL_NAME the app will find"
cp "$MODEL" "$DEST/$MODEL_NAME"

# The recording is copied into the container too: `simctl launch` cannot reach
# a host path from inside the simulator.
cp "$WAV" "$CONTAINER/Documents/$(basename "$WAV")"
WAV_IN_SIM="$CONTAINER/Documents/$(basename "$WAV")"

# The engine choice lives in UserDefaults, which the app reads at launch, so it
# is written before the run rather than tapped. The app is launched once first
# so the container has a preferences file to write into.
xcrun simctl launch "$UDID" app.cqutmux.ios >/dev/null || true
sleep 2
xcrun simctl terminate "$UDID" app.cqutmux.ios >/dev/null 2>&1 || true

PLIST="$CONTAINER/Library/Preferences/app.cqutmux.ios.plist"
ENGINE="${CQUT_ENGINE:-whisper}"
if [ "$ENGINE" = "parakeet" ]; then
  MODEL_KEY="cqutmux.speech.parakeetModel"
else
  MODEL_KEY="cqutmux.speech.whisperModel"
fi
/usr/libexec/PlistBuddy -c "Add :cqutmux.speech.engine string $ENGINE" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :cqutmux.speech.engine $ENGINE" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :$MODEL_KEY string $MODEL_NAME" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :$MODEL_KEY $MODEL_NAME" "$PLIST"

sleep 1
echo "==> launching with $ENGINE selected and the recording staged"
SIMCTL_CHILD_CQUT_DEV_NO_NOTIFS=1 \
SIMCTL_CHILD_CQUT_DEV_TRANSCRIBE="$WAV_IN_SIM" \
  xcrun simctl launch "$UDID" app.cqutmux.ios >/dev/null

echo "==> transcribing (tiny.en on CPU is a couple of seconds for 11s of audio)"
RESULT="$CONTAINER/Documents/transcript.txt"
for _ in $(seq 1 30); do
  [ -f "$RESULT" ] && break
  sleep 2
done

if [ ! -f "$RESULT" ]; then
  echo "==> FAIL: no transcript after 60s" >&2
  xcrun simctl io "$UDID" screenshot "$SHOT" >/dev/null 2>&1 || true
  exit 1
fi

cat "$RESULT"
# A couple of distinctive words from whichever recording was supplied, rather
# than the whole sentence, so a different punctuation choice is not a failure.
# CQUT_EXPECT overrides, for a recording this script has never seen.
case "$(basename "$WAV")" in
  jfk.wav) DEFAULT_EXPECT="country ask" ;;
  speech.wav) DEFAULT_EXPECT="Phoebe portrait" ;;
  *) DEFAULT_EXPECT="" ;;
esac
EXPECT="${CQUT_EXPECT:-$DEFAULT_EXPECT}"

ok=0
if grep -q TRANSCRIBE_OK "$RESULT"; then
  ok=1
  for word in $EXPECT; do
    grep -qi "$word" "$RESULT" || ok=0
  done
fi

if [ "$ok" = "1" ]; then
  echo "==> PASS: the app loaded a $ENGINE model and recognised the recording"
else
  echo "==> FAIL: unexpected transcript" >&2
  exit 1
fi