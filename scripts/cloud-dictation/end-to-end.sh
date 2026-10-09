#!/usr/bin/env bash
#
# Drives the Cloud dictation engine inside the app against a real HTTP server,
# with a recording standing in for the microphone.
#
# The microphone is the one part of dictation a simulator cannot drive, but
# everything downstream is the shipped path: the WAV the engine builds, the
# headers it sets, the request it posts, the answer it parses, and the string
# the terminal would have received. The server writes down what actually
# arrived, so the header can be read on the other end rather than inferred from
# the transcript.
#
# Usage: scripts/cloud-dictation/end-to-end.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEVICE="${CQUT_DEVICE:-iPhone 18 Pro}"
BUNDLE="app.cqutmux.ios"
PORT="${CQUT_CLOUD_PORT:-24817}"
TOKEN="s3cret-cloud-token"
OUT="$(mktemp -d)"
DUMP="$OUT/request.json"
REPLY="$OUT/reply.json"
PASS=0

cleanup() {
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$OUT"
}
trap cleanup EXIT

note() { printf '\n== %s\n' "$1"; }
ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; exit 1; }

# MARK: - A recording to post

# 0.2 s of a 440 Hz tone, as 16-bit PCM. Long enough to clear the engine's
# quarter-second floor is not needed here — the harness calls the request path
# directly — but it does need to be a real WAV so the bytes mean something.
AUDIO="$OUT/tone.wav"
python3 -I - "$AUDIO" <<'PY'
import math, struct, sys, wave
path = sys.argv[1]
rate, seconds = 16000, 0.2
with wave.open(path, "w") as f:
    f.setnchannels(1); f.setsampwidth(2); f.setframerate(rate)
    frames = b"".join(
        struct.pack("<h", int(16000 * math.sin(2 * math.pi * 440 * i / rate)))
        for i in range(int(rate * seconds))
    )
    f.writeframes(frames)
PY
[ -s "$AUDIO" ] || fail "could not build the test recording"

# MARK: - Boot the app's environment

note "Booting $DEVICE"
xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || true
xcrun simctl terminate "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true

# A leftover listener makes every case fail as "could not connect", which looks
# exactly like the app being broken. Say so instead of misattributing it.
if lsof -ti ":$PORT" >/dev/null 2>&1; then
  fail "port $PORT is already in use — kill the listener or set CQUT_CLOUD_PORT"
fi

# MARK: - Case 1: a well-formed answer

note "Case 1 — server answers {\"text\": …}"
printf '%s' '{"status":200,"body":{"text":"hello from the endpoint"}}' > "$REPLY"
node "$ROOT/scripts/cloud-dictation/server.mjs" "$PORT" "$REPLY" "$DUMP" > "$OUT/server.log" 2>&1 &
SERVER_PID=$!
sleep 1
grep -q listening "$OUT/server.log" || fail "the endpoint did not start"

CONTAINER="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data 2>/dev/null || true)"
[ -n "$CONTAINER" ] || fail "the app is not installed; run scripts/build.sh first"
cp "$AUDIO" "$CONTAINER/Documents/cloud-tone.wav"

# Cleared before the launch that should write it. Without this the poll below
# finds a previous run's report instantly and every case "passes" against
# whatever the last one said — including a failure, which then gets attributed
# to the wrong case.
rm -f "$CONTAINER/Documents/cloud-transcript.txt"

xcrun simctl terminate "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true
SIMCTL_CHILD_CQUT_DEV_CLOUD_TRANSCRIBE="$CONTAINER/Documents/cloud-tone.wav" \
SIMCTL_CHILD_CQUT_DEV_CLOUD_URL="http://127.0.0.1:$PORT/v1/audio/transcriptions" \
SIMCTL_CHILD_CQUT_DEV_CLOUD_TOKEN="$TOKEN" \
SIMCTL_CHILD_CQUT_DEV_CLOUD_LANGUAGE="en" \
SIMCTL_CHILD_CQUT_DEV_NO_NOTIFS=1 \
  xcrun simctl launch "$DEVICE" "$BUNDLE" >/dev/null

for _ in $(seq 1 40); do
  [ -s "$CONTAINER/Documents/cloud-transcript.txt" ] && break
  sleep 0.5
done
REPORT="$(cat "$CONTAINER/Documents/cloud-transcript.txt" 2>/dev/null || true)"
[ -n "$REPORT" ] || fail "the app wrote no report"

echo "$REPORT"
echo "$REPORT" | grep -q "CLOUD_TRANSCRIBE_OK" || fail "the request did not succeed"
echo "$REPORT" | grep -q "hello from the endpoint" || fail "the transcript was not the server's text"
ok "the engine posts and reads back the served transcript"

# MARK: - What actually arrived

note "The request the server received"
cat "$DUMP"
[ -s "$DUMP" ] || fail "the server recorded no request"

json() { python3 -I -c "import json,sys; print(json.load(open('$DUMP'))$1)"; }

[ "$(json "['method']")" = "POST" ] || fail "not a POST"
[ "$(json "['url']")" = "/v1/audio/transcriptions" ] || fail "wrong path"
[ "$(json "['contentType']")" = "application/json" ] || fail "wrong content type"
[ "$(json "['authorization']")" = "Bearer $TOKEN" ] || fail "the bearer token was not sent"
[ "$(json "['wav']['consistent']")" = "True" ] || fail "the WAV header is not self-consistent"
[ "$(json "['wav']['channels']")" = "1" ] || fail "not mono"
[ "$(json "['wav']['sampleRate']")" = "16000" ] || fail "not 16 kHz"
[ "$(json "['wav']['bitsPerSample']")" = "16" ] || fail "not 16-bit"
[ "$(json "['wav']['language']")" = "en" ] || fail "the language did not survive"
ok "request shape: POST, JSON, bearer token, consistent 16 kHz mono WAV, language carried"

# MARK: - Case 2: a bare string

note "Case 2 — server answers a bare JSON string"
printf '%s' '{"status":200,"body":"a bare string"}' > "$REPLY"
# The server JSON-encodes `body`, so a string body arrives as a quoted string —
# which is the shape the parser must also accept.
rm -f "$CONTAINER/Documents/cloud-transcript.txt"
kill "$SERVER_PID" 2>/dev/null || true
node "$ROOT/scripts/cloud-dictation/server.mjs" "$PORT" "$REPLY" "$DUMP" > "$OUT/server.log" 2>&1 &
SERVER_PID=$!
sleep 1
xcrun simctl terminate "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true
SIMCTL_CHILD_CQUT_DEV_CLOUD_TRANSCRIBE="$CONTAINER/Documents/cloud-tone.wav" \
SIMCTL_CHILD_CQUT_DEV_CLOUD_URL="http://127.0.0.1:$PORT/v1/audio/transcriptions" \
SIMCTL_CHILD_CQUT_DEV_NO_NOTIFS=1 \
  xcrun simctl launch "$DEVICE" "$BUNDLE" >/dev/null
for _ in $(seq 1 40); do
  [ -s "$CONTAINER/Documents/cloud-transcript.txt" ] && break
  sleep 0.5
done
REPORT="$(cat "$CONTAINER/Documents/cloud-transcript.txt" 2>/dev/null || true)"
echo "$REPORT"
echo "$REPORT" | grep -q "a bare string" || fail "the bare-string answer was not accepted"
[ "$(json "['authorization']")" = "None" ] || fail "a token was sent when none was configured"
ok "accepts a bare-string answer, and sends no Authorization header without a token"

# MARK: - Case 3: a server error

note "Case 3 — server answers 503"
printf '%s' '{"status":503,"body":{"error":"down"}}' > "$REPLY"
rm -f "$CONTAINER/Documents/cloud-transcript.txt"
kill "$SERVER_PID" 2>/dev/null || true
node "$ROOT/scripts/cloud-dictation/server.mjs" "$PORT" "$REPLY" "$DUMP" > "$OUT/server.log" 2>&1 &
SERVER_PID=$!
sleep 1
xcrun simctl terminate "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true
SIMCTL_CHILD_CQUT_DEV_CLOUD_TRANSCRIBE="$CONTAINER/Documents/cloud-tone.wav" \
SIMCTL_CHILD_CQUT_DEV_CLOUD_URL="http://127.0.0.1:$PORT/v1/audio/transcriptions" \
SIMCTL_CHILD_CQUT_DEV_NO_NOTIFS=1 \
  xcrun simctl launch "$DEVICE" "$BUNDLE" >/dev/null
for _ in $(seq 1 40); do
  [ -s "$CONTAINER/Documents/cloud-transcript.txt" ] && break
  sleep 0.5
done
REPORT="$(cat "$CONTAINER/Documents/cloud-transcript.txt" 2>/dev/null || true)"
echo "$REPORT"
echo "$REPORT" | grep -q "CLOUD_TRANSCRIBE_FAIL" || fail "a 503 was reported as success"
# The message, not just the fact: `"\(error)"` would also contain "503", as
# `badStatus(503)`, and that is not a sentence anyone can read in a status line.
echo "$REPORT" | grep -q "The endpoint answered 503" || fail "the failure did not use its readable message"
echo "$REPORT" | grep -qv "badStatus" || fail "the failure printed the enum case instead of the message"
ok "a non-2xx answer fails loudly with the message written for the user"

printf '\nCLOUD_E2E_PASS  (%d cases)\n' "$PASS"