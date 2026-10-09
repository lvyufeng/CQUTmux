#!/usr/bin/env bash
#
# Checks the transcript reader: what a chat view is given for a session log.
#
# The reader exists because the log format is internal to the agent and changes
# between releases. That makes two things worth checking, and they pull in
# opposite directions: it must extract the conversation faithfully, and it must
# never throw — a session log we cannot read has to degrade to "no chat", not to
# a broken gateway.
#
# The fixtures here are the shapes observed in a real transcript, including the
# ones easy to get wrong: a tool result arriving as a *user* record, a
# half-written last line, an image block carrying megabytes of base64.
#
# Usage: scripts/transcript-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD="$ROOT/host/cqutmux-hook/transcript.mjs"
PASS=0

ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; exit 1; }

node --input-type=module -e "
import { parseTranscript, messageFromRecord } from '$MOD'

let pass = 0
const ok  = (c, m) => { if (!c) { console.log('FAIL  ' + m); process.exit(1) } pass++; console.log('PASS  ' + m) }

// MARK: - The conversation, in order

const lines = [
  JSON.stringify({ type: 'user', uuid: 'u1', timestamp: '2026-01-01T00:00:00Z',
    message: { role: 'user', content: 'rename the widget' } }),
  JSON.stringify({ type: 'assistant', uuid: 'a1', timestamp: '2026-01-01T00:00:01Z',
    message: { role: 'assistant', model: 'claude', content: [
      { type: 'thinking', thinking: 'they mean the sidebar widget' },
      { type: 'text', text: 'Looking at it now.' },
      { type: 'tool_use', id: 't1', name: 'Read', input: { file_path: '/a/b.swift' } } ] } }),
  JSON.stringify({ type: 'user', uuid: 'u2', timestamp: '2026-01-01T00:00:02Z',
    message: { role: 'user', content: [ { type: 'tool_result', tool_use_id: 't1', content: 'let x = 1' } ] } }),
].join('\n')

const msgs = parseTranscript(lines)
ok(msgs.length === 3, 'three records become three messages (got ' + msgs.length + ')')
ok(msgs[0].role === 'user', 'the first message is the user speaking')
ok(msgs[0].blocks[0].text === 'rename the widget', 'the user text is carried through')
ok(msgs[1].role === 'assistant', 'the second is the assistant')

// MARK: - One assistant turn is one message with its blocks in order

const a = msgs[1].blocks
ok(a.length === 3, 'thinking, text and tool use are three blocks (got ' + a.length + ')')
ok(a[0].kind === 'thinking', 'reasoning is its own block, not folded into the answer')
ok(a[1].kind === 'text', 'the answer text follows')
ok(a[2].kind === 'tool' && a[2].name === 'Read', 'the tool call keeps its name')
ok(a[2].input.includes('/a/b.swift'), 'the tool call keeps its input')
ok(a[2].id === 't1', 'the tool call keeps the id a result will refer to')

// MARK: - A tool result is not the user speaking

const result = msgs[2]
ok(result.role === 'tool', 'a tool result is its own role, not \\'user\\' (got ' + result.role + ')')
ok(result.blocks[0].kind === 'result', 'it is a result block')
ok(result.blocks[0].text === 'let x = 1', 'the result text is carried through')
ok(result.blocks[0].id === 't1', 'the result names the tool call it answers')

// MARK: - A user record that really is a person is still the user

const mixed = parseTranscript(JSON.stringify({ type: 'user', uuid: 'u3',
  message: { role: 'user', content: 'just talking' } }))
ok(mixed[0].role === 'user', 'a plain user record stays the user')

// MARK: - Never throws, never guesses

ok(parseTranscript('').length === 0, 'empty input yields nothing')
ok(parseTranscript('not json at all').length === 0, 'garbage yields nothing, and does not throw')
ok(parseTranscript('{\"type\":\"user\"').length === 0, 'a half-written last line is skipped')

// The file is appended to while we read it, so a truncated tail is the normal
// case, not an error. The complete lines before it must still come through.
const truncated = lines + '\n{\"type\":\"assistant\",\"mess'
ok(parseTranscript(truncated).length === 3, 'a truncated final line still leaves the rest readable')

ok(parseTranscript(JSON.stringify({ type: 'file-history-snapshot', snapshot: {} })).length === 0,
   'a non-message record is ignored')
ok(parseTranscript(JSON.stringify({ type: 'assistant', message: { content: [] } })).length === 0,
   'an empty message is dropped rather than shown as a blank row')
ok(parseTranscript(JSON.stringify({ type: 'assistant', message: { model: 'x', content: [
   { type: 'someFutureBlock', whatever: 1 }] } })).length === 0,
   'an unknown block type is dropped, not guessed at')

// MARK: - Sidechains are not the main conversation

const side = parseTranscript(JSON.stringify({ type: 'assistant', isSidechain: true,
  message: { content: [{ type: 'text', text: 'from a subagent' }] } }))
ok(side.length === 0, 'a subagent sidechain stays out of the main conversation')

// MARK: - Bounded output

// Tool results include whole files. A chat line is not the place for one.
const big = { type: 'user', uuid: 'u9', message: { role: 'user', content: [
  { type: 'tool_result', tool_use_id: 't9', content: 'x'.repeat(20000) } ] } }
const clamped = parseTranscript(JSON.stringify(big))
ok(clamped[0].blocks[0].text.length < 6000,
   'a huge tool result is clamped (got ' + clamped[0].blocks[0].text.length + ')')
ok(clamped[0].blocks[0].text.includes('more characters'),
   'and says how much was cut rather than trailing off')

// An image block is base64, often megabytes. Shipping it to render one chat
// line is not a trade worth making.
const withImage = parseTranscript(JSON.stringify({ type: 'user', uuid: 'u10', message: { role: 'user', content: [
  { type: 'tool_result', tool_use_id: 't10', content: [
    { type: 'text', text: 'screenshot attached' },
    { type: 'image', source: { data: 'A'.repeat(50000) } } ] } ] } }))
ok(withImage[0].blocks[0].text === 'screenshot attached',
   'an image block contributes nothing to the text')
ok(withImage[0].blocks[0].text.length < 100, 'and none of its base64 comes through')

// MARK: - Errors are marked

const errored = parseTranscript(JSON.stringify({ type: 'user', uuid: 'u11', message: { role: 'user', content: [
  { type: 'tool_result', tool_use_id: 't11', content: 'boom', is_error: true } ] } }))
ok(errored[0].blocks[0].isError === true, 'a failed tool result is marked as an error')

console.log('')
console.log('TRANSCRIPT_PASS  (' + pass + ' checks)')
" || fail "the transcript reader did not pass its checks"

printf '\nTRANSCRIPT_OK\n'