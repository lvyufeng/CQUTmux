#!/usr/bin/env bash
#
# Checks that the microphone button tells the truth and that a press-and-hold
# ends when the finger comes up.
#
# Usage: scripts/dictation-hold-check.sh
#
# The bug this exists to keep out
# ------------------------------
# `Dictation.isListening` was assigned from the engine immediately after the
# call that starts it — `isListening = apple.isListening`, `isListening =
# engine.isRecording` — and every engine reaches its recording state inside a
# `Task`. So the flag was false at the moment it was written and nothing ever
# wrote it again: the icon never showed listening, and the hold's stop was
# guarded on that flag, so releasing the button stopped nothing and the
# microphone stayed open until the next tap.
#
# What is asserted here
# ---------------------
# The shape, not the behaviour. Whether a hold actually stops needs a
# microphone and a running app; what a source read can prove is that the flag
# is no longer sourced from a synchronous engine read, that a stop arriving
# before the engine has started recording is remembered rather than dropped,
# and that the gesture's start sits on the long press's own recognition rather
# than on the press-state callback — which fires for taps too, and starting
# there is what made every tap begin a dictation the button then had to end.
#
# What this does NOT prove: that the recognised hold has the duration the
# threshold says, or that a release is delivered at all. Both are SwiftUI's,
# and this environment cannot press the button.
#
# Comments are stripped before anything is counted. The fix discusses
# `isListening` and `dictation?.start` in prose, and a check that counted its
# own explanation would pass against a tree whose only start was a sentence
# describing one.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VOICE="App/Features/Voice/SpeechSettings.swift"
TERM="App/Features/Terminal/TerminalViewRepresentable.swift"

checks=0
fail=0
check() { # <condition> <label>
  checks=$((checks + 1))
  if [ "$1" = "1" ]; then
    printf 'PASS  %s\n' "$2"
  else
    printf 'FAIL  %s\n' "$2"
    fail=1
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

code_of() { grep -vE '^[[:space:]]*//' "$1" > "$WORK/$(basename "$1").code" && echo "$WORK/$(basename "$1").code"; }
VOICE_CODE="$(code_of "$VOICE")"
TERM_CODE="$(code_of "$TERM")"

present() { grep -qF "$1" "$2" && echo 1 || echo 0; }
count() { grep -cF "$1" "$2" 2>/dev/null || true; }

echo "==> isListening is a request, not a snapshot"

# The load-bearing one. Any assignment whose right-hand side asks an engine
# whether it is recording is the bug, whatever it is called.
from_engine="$(grep -cE 'isListening = .*(isListening|isRecording)' "$VOICE_CODE" || true)"
check "$([ "$from_engine" = "0" ] && echo 1 || echo 0)" \
  "isListening is never assigned from an engine's own state (found $from_engine)"
check "$(present 'isListening = true' "$VOICE_CODE")" \
  "asking to dictate counts as listening straight away"
check "$(present 'engineIsRecording' "$VOICE_CODE")" \
  "and the engine's state is read where a decision depends on it"

echo "==> a stop that arrives before the engine does is remembered"

# The whisper model takes a second or two on the first phrase, which is longer
# than a press-and-hold lasts. A stop dropped there leaves the engine to begin
# recording with nobody holding the button.
check "$(present 'stopWhenStarted' "$VOICE_CODE")" \
  "a stop with nothing to stop is held over"
check "$(present 'stopWhenStarted = true' "$VOICE_CODE")" \
  "it is set on the stop path"
check "$(present 'else if stopWhenStarted, engineIsRecording' "$VOICE_CODE")" \
  "and honoured when the engine finally starts"

echo "==> a release ends the phrase, it does not discard it"

# `finish` transcribes; `stop`/`cancel` throws the recording away. Both the
# release and the second tap mean "send what I said", so neither may cancel.
#
# The Apple engine is the exception and not an oversight: `VoiceDictation`
# streams as it listens and hands the phrase back through `onUpdate`, so
# `stop()` there ends the recogniser rather than dropping a recording. The two
# that record first — whisper and cloud — are the two this pins.
end_body="$(awk '/private func endEngine/,/^    \}/' "$VOICE_CODE")"
check "$(printf '%s' "$end_body" | grep -qF 'finish(' && echo 1 || echo 0)" \
  "ending sends the phrase to be transcribed"
check "$(printf '%s' "$end_body" | grep -qE '(whisper|cloud)\?\.(stop|cancel)\(' && echo 0 || echo 1)" \
  "and never takes the discarding path on the engines that record first"

echo "==> the engines are watched rather than read once"

check "$(present 'withObservationTracking' "$VOICE_CODE")" \
  "the selected engine is observed"
check "$(present 'private func settle()' "$VOICE_CODE")" \
  "and reconciled when it moves"
check "$(present 'problem = engineProblem' "$VOICE_CODE")" \
  "a failure is re-read rather than cached from before the Task ran"

echo "==> the gesture starts on the hold, not on the press"

# `.onLongPressGesture`'s perform closure is the hold: SwiftUI recognises the
# gesture when its threshold elapses with the finger down. The press-state
# callback fires for a tap as well.
# The perform closure alone, up to the argument label that opens the other
# one: taking the whole call would let the press-state callback's body satisfy
# every assertion below, which is exactly the arrangement being ruled out.
hold="$(awk '/\.onLongPressGesture\(minimumDuration: 0.35/,/\} onPressingChanged:/' "$TERM_CODE")"
gesture="$(awk '/\.onLongPressGesture\(minimumDuration: 0.35/,/^    \}/' "$TERM_CODE")"
check "$(printf '%s' "$hold" | grep -qF 'dictation?.start(' && echo 1 || echo 0)" \
  "the hold starts dictation"
check "$(printf '%s' "$gesture" | grep -qF 'holdingDictation = true' && echo 1 || echo 0)" \
  "and records that this press was a hold"
check "$(printf '%s' "$gesture" | grep -qF 'guard !pressing, holdingDictation else { return }' && echo 1 || echo 0)" \
  "so only a release that ended a hold stops one"

check "$([ "$(count 'dictation?.start(' "$TERM_CODE")" = "1" ] && echo 1 || echo 0)" \
  "there is exactly one place dictation is started from the bar"
check "$([ "$(grep -cE 'dictation\?\.isListening == (true|false)' "$TERM_CODE" || true)" = "0" ] && echo 1 || echo 0)" \
  "and nothing gates on the flag that used to be read before it was set"

if [ "$fail" != "0" ]; then
  printf '\nDICTATION_HOLD_FAIL  (%s checks)\n' "$checks"
  exit 1
fi
printf '\nDICTATION_HOLD_PASS  (%s checks)\n' "$checks"