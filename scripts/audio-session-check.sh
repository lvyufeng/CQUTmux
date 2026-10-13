#!/usr/bin/env bash
#
# Checks that every engine which takes the microphone gives it back.
#
# Usage: scripts/audio-session-check.sh
#
# What is asserted
# ----------------
# An audio session is a resource held on behalf of the whole device, not of
# this process. `begin()` in every one of these engines activates it as
# `.record` with `.duckOthers`; leaving it active keeps other apps' audio
# ducked for as long as this app stays in the foreground, and nothing in this
# app plays audio, so nothing here would ever notice.
#
# `CloudDictation` was the one engine that activated a session and never
# deactivated it — the other two had torn down correctly since they were
# written. So this check does not test the engines' behaviour (that needs a
# microphone and a simulator); it tests the *shape*, from the source:
#
# 1. Exactly one activation per engine file, so there is one thing to pair.
# 2. Exactly one `engine.stop()` per engine, and it lives inside the engine's
#    teardown. This is the load-bearing one. `engine.stop()` is what actually
#    releases the microphone, so if there is only one and it sits next to the
#    `setActive(false`, then no path can stop the mic without also releasing
#    the session. It is why a fix that reorders the calls still passes and a
#    fix that leaves a second `engine.stop()` somewhere does not.
# 3. The teardown's own body contains the `setActive(false`.
# 4. The stop and finish paths reach the teardown.
#
# What this does NOT prove: that the call is unconditional. Reachability here
# is one hop, and a `return` placed above the teardown call would still pass.
# That is the honest limit of a source-level check, and it is why 2 exists —
# the count is what makes the one hop sufficient.
#
# Comments are stripped before anything is counted. This is not fastidiousness:
# the fix for the bug being checked discusses `setActive(false)` in a doc
# comment, and a check that counted that prose would pass against a tree whose
# only deactivation was a sentence saying to deactivate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CLOUD="App/Features/Voice/CloudDictation.swift"
VOICE="App/Features/Voice/VoiceDictation.swift"
WHISPER="Packages/CQUTWhisper/Sources/CQUTWhisper/WhisperDictation.swift"

for f in "$CLOUD" "$VOICE" "$WHISPER"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: $f is missing — this check names the engines explicitly"
    exit 1
  fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Source with whole-line comments dropped. Every count below runs on this.
code_of() { grep -vE '^[[:space:]]*//' "$1"; }

# The body of the first function whose declaration contains the given literal,
# up to the first line that is exactly four spaces and a brace — the class's
# own closing indentation, which no nested block reaches.
body_of() { # <file> <literal from the declaration line>
  local start
  start="$(grep -nF "$2" "$1" | head -1 | cut -d: -f1 || true)"
  if [ -z "$start" ]; then
    echo "<<no declaration matching: $2>>"
    return 0
  fi
  awk -v s="$start" 'NR > s { if ($0 == "    }") exit; print }' "$1"
}

count() { # <file> <pattern> -> occurrences in code, not comments
  code_of "$1" | grep -cF "$2" || true
}

fails=0
checks=0
check() { # <condition: 1|0> <label>
  checks=$((checks + 1))
  if [ "$1" = "1" ]; then
    printf '  ok    %s\n' "$2"
  else
    printf '  FAIL  %s\n' "$2"
    fails=$((fails + 1))
  fi
}

has() { case "$1" in *"$2"*) echo 1 ;; *) echo 0 ;; esac; }

echo "==> every engine that activates a session is one of the known three"

# Discovered rather than listed, so a fourth engine fails here instead of
# slipping past an assertion that only ever looked at three paths.
# Not `mapfile`: macOS ships bash 3.2 and the checks run on the stock shell.
activators="$(grep -rlF 'setActive(true' App Packages --include='*.swift' | sort || true)"
expected="$(printf '%s\n' "$CLOUD" "$VOICE" "$WHISPER" | sort)"
check "$([ "$activators" = "$expected" ] && echo 1 || echo 0)" \
  "exactly the three known engines activate a session (found: $(printf '%s' "$activators" | tr '\n' ' '))"

echo "==> one activation, one teardown, and the teardown is where the mic is released"

for spec in "$CLOUD|func tearDown()" "$VOICE|func tearDown()" "$WHISPER|func tearDownSync()"; do
  f="${spec%%|*}"
  decl="${spec#*|}"
  name="$(basename "$f")"
  teardown="$(body_of "$f" "$decl")"

  check "$([ "$(count "$f" 'setActive(true')" -eq 1 ] && echo 1 || echo 0)" \
    "$name activates the session in exactly one place"
  check "$(has "$teardown" 'setActive(false')" \
    "$name releases it in $decl"

  stops="$(count "$f" 'engine.stop()')"
  check "$([ "$stops" -eq 1 ] && echo 1 || echo 0)" \
    "$name stops the engine in exactly one place (found $stops)"
  check "$(has "$teardown" 'engine.stop()')" \
    "$name's only engine.stop() is inside $decl"

  # Reaching the teardown from begin() as well would mean the check above is
  # satisfied by the wrong call site; begin() is where the tap goes on.
  begin="$(body_of "$f" 'func begin(')"
  check "$([ "$(has "$begin" 'engine.stop()')" = "0" ] && echo 1 || echo 0)" \
    "$name does not stop the engine from begin()"
done

echo "==> the stop and finish paths reach the teardown"

cloud_stop="$(body_of "$CLOUD" 'func stop()')"
check "$(has "$cloud_stop" 'tearDown()')" \
  "CloudDictation.stop() tears down"

cloud_finish="$(body_of "$CLOUD" 'func finish(')"
check "$(has "$cloud_finish" 'tearDown()')" \
  "CloudDictation.finish() tears down"

# Ordering, because the bug had a second half: the short-tap path returns
# early. A teardown placed after that guard would fix the normal transcript
# and leave the session held for every tap the user makes to test the button.
teardown_line="$(printf '%s\n' "$cloud_finish" | grep -nF 'tearDown()' | head -1 | cut -d: -f1 || true)"
floor_line="$(printf '%s\n' "$cloud_finish" | grep -nF 'guard audio.count' | head -1 | cut -d: -f1 || true)"
check "$([ -n "$teardown_line" ] && [ -n "$floor_line" ] \
  && [ "$teardown_line" -lt "$floor_line" ] && echo 1 || echo 0)" \
  "CloudDictation releases the session before the short-tap early return"

send_line="$(printf '%s\n' "$cloud_finish" | grep -nF 'send(audio' | head -1 | cut -d: -f1 || true)"
check "$([ -n "$teardown_line" ] && [ -n "$send_line" ] \
  && [ "$teardown_line" -lt "$send_line" ] && echo 1 || echo 0)" \
  "CloudDictation releases the session before the upload starts"

voice_stop="$(body_of "$VOICE" 'func stop()')"
check "$(has "$voice_stop" 'tearDown()')" \
  "VoiceDictation.stop() tears down"

whisper_finish="$(body_of "$WHISPER" 'func finish(')"
check "$(has "$whisper_finish" 'tearDownSync()')" \
  "WhisperDictation.finish() tears down"

if [ "$fails" -ne 0 ]; then
  echo "AUDIO_SESSION_FAIL ($fails of $checks failed)"
  exit 1
fi

echo "AUDIO_SESSION_PASS ($checks checks)"