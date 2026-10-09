#!/usr/bin/env bash
#
# Fetches a whisper model for testing. The app downloads models through
# WhisperModelStore; this is for the scripts, which need one on disk before the
# app has ever run.
#
# Not vendored into the repository: the smallest useful model is 32 MB and the
# set runs past 3 GB, and the app's own downloads come from the same place.
#
# Usage: scripts/whisper-ios/model.sh [name] [destination]
set -euo pipefail

NAME="${1:-ggml-tiny.en.bin}"
DEST="${2:-/tmp/whisper-models}"
BASE="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

mkdir -p "$DEST"
if [ -f "$DEST/$NAME" ]; then
  echo "already have $DEST/$NAME"
  exit 0
fi

echo "==> downloading $NAME"
curl -fL --progress-bar -o "$DEST/$NAME.part" "$BASE/$NAME"
mv "$DEST/$NAME.part" "$DEST/$NAME"

# The catalog in Packages/CQUTWhisper/Sources/CQUTWhisperC/whisper_shim.c
# carries the expected digest for every model it offers; a mismatch here means
# the download is not the file the app would accept.
echo "    $(shasum -a 256 "$DEST/$NAME" | cut -d' ' -f1)  $NAME"