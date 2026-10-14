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
FIXTURE="$ROOT/scripts/transcript/codex-rollout.jsonl"
PASS=0

ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; exit 1; }

node --input-type=module -e "
import { parseTranscript, parseTranscriptFor, agentIds, claudeProjectDir, readTranscript } from '$MOD'
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, utimesSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

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

// MARK: - Token usage rides along

// The Inbox context ring reads tokens from here, not from the events the
// gateway emits — the events carry no counts. So the usage block has to come
// through on assistant turns.
const withUsage = parseTranscript(JSON.stringify({ type: 'assistant', uuid: 'a12',
  message: { role: 'assistant', model: 'claude', content: [{ type: 'text', text: 'done' }],
    usage: { input_tokens: 100, cache_read_input_tokens: 20, cache_creation_input_tokens: 5,
             output_tokens: 7, service_tier: 'standard', iterations: [1, 2] } } }))
ok(withUsage[0].usage && withUsage[0].usage.input_tokens === 100,
   'an assistant turn carries its usage block')
ok(withUsage[0].usage.cache_read_input_tokens === 20
   && withUsage[0].usage.cache_creation_input_tokens === 5
   && withUsage[0].usage.output_tokens === 7,
   'and every token count, not just the first')
ok(withUsage[0].usage.service_tier === undefined && withUsage[0].usage.iterations === undefined,
   'non-numeric usage fields are dropped, not carried as-is')

// A count that arrives as a string would be summed as zero on the phone, which
// reads as an empty context window rather than as a malformed field.
const stringy = parseTranscript(JSON.stringify({ type: 'assistant', uuid: 'a13',
  message: { role: 'assistant', content: [{ type: 'text', text: 'x' }],
    usage: { input_tokens: '100', output_tokens: 7 } } }))
ok(stringy[0].usage && stringy[0].usage.input_tokens === undefined
   && stringy[0].usage.output_tokens === 7,
   'a numeric-looking string is dropped while the real numbers survive')

// A turn with no usage must not sprout one.
const noUsage = parseTranscript(JSON.stringify({ type: 'user', uuid: 'u14',
  message: { role: 'user', content: 'hello' } }))
ok(noUsage[0].usage === null, 'a message with no usage reports none')

// MARK: - The agent registry
//
// The reader is a registry, one entry per agent, rather than one parser with a
// per-agent branch threaded through it. The parsers must not be interchangeable:
// a Claude record read with Codex's rules (or the reverse) is a wrong answer
// that renders fine, so the agent is named and a record is only ever read by the
// parser that owns it.

const ids = agentIds()
ok(ids[0] === 'claude-code', 'Claude Code is the first agent in the registry (got ' + ids[0] + ')')
ok(ids.includes('codex'), 'Codex is a registered agent')

// The named Claude parser and the back-compatible default are the same reader:
// 'parseTranscript' is the old entry point and must not drift from the registry.
ok(JSON.stringify(parseTranscriptFor('claude-code', lines)) === JSON.stringify(parseTranscript(lines)),
   'the named Claude parser agrees with the default entry point')

// An agent the registry does not know yields nothing rather than throwing — the
// same 'no chat yet' degradation an unreadable log gets.
ok(parseTranscriptFor('some-future-agent', lines).length === 0,
   'an unregistered agent parses to nothing, and does not throw')

// A Claude record fed to the Codex parser must not be read as a Codex one: both
// are JSON with a 'type', and a shared parser would read this line.
ok(parseTranscriptFor('codex', lines).length === 0,
   'a Claude transcript is not read by the Codex parser')

// MARK: - Codex (written from openai/codex source, not a real rollout)
//
// These fixtures are built from the documented shape — a rollout line of
// '{ timestamp, type, payload }' whose 'type' is 'response_item' — and NOT from
// a captured file. They prove the parser reads the shape it was written for,
// and the cases a short capture does not happen to contain — an unknown item
// type, an image input, a truncated tail. That the shape is what Codex really
// writes is what the capture below settles.

const codexLines = [
  JSON.stringify({ timestamp: '2026-01-01T00:00:00Z', type: 'session_meta',
    payload: { id: 'thread-1', cwd: '/work/demo', cli_version: '0.1', originator: 'codex_cli' } }),
  JSON.stringify({ timestamp: '2026-01-01T00:00:01Z', type: 'turn_context',
    payload: { cwd: '/work/demo', model: 'gpt-5-codex', approval_policy: 'never' } }),
  JSON.stringify({ timestamp: '2026-01-01T00:00:02Z', type: 'response_item',
    payload: { type: 'message', role: 'user',
      content: [{ type: 'input_text', text: 'list the files' }] } }),
  JSON.stringify({ timestamp: '2026-01-01T00:00:03Z', type: 'response_item',
    payload: { type: 'reasoning', summary: [{ type: 'summary_text', text: 'they want a listing' }] } }),
  JSON.stringify({ timestamp: '2026-01-01T00:00:04Z', type: 'response_item',
    payload: { type: 'function_call', name: 'shell', call_id: 'c1', arguments: '{\"command\":\"ls\"}' } }),
  JSON.stringify({ timestamp: '2026-01-01T00:00:05Z', type: 'response_item',
    payload: { type: 'function_call_output', call_id: 'c1', output: 'a.txt' } }),
  JSON.stringify({ timestamp: '2026-01-01T00:00:06Z', type: 'response_item',
    payload: { type: 'message', role: 'assistant',
      content: [{ type: 'output_text', text: 'Just a.txt.' }] } }),
].join('\n')

const codex = parseTranscriptFor('codex', codexLines)
ok(codex.length === 5, 'a Codex rollout reads as five messages (got ' + codex.length + ')')
ok(codex[0].role === 'user' && codex[0].blocks[0].text === 'list the files',
   'a Codex input_text message is the user speaking')
ok(codex[1].blocks[0].kind === 'thinking' && codex[1].blocks[0].text === 'they want a listing',
   'a Codex reasoning summary is reasoning, not the answer')
ok(codex[2].blocks[0].kind === 'tool' && codex[2].blocks[0].name === 'shell',
   'a Codex function_call is a tool block with its name')
ok(codex[2].blocks[0].input.includes('command'),
   'and its arguments string is carried through as JSON text')
ok(codex[3].role === 'tool' && codex[3].blocks[0].text === 'a.txt',
   'a Codex function_call_output is a tool result, not the user')
ok(codex[3].blocks[0].id === 'c1', 'the Codex result names the call it answers')
ok(codex[2].blocks[0].id === 'c1', 'and the call carries the same id')

// session_meta and turn_context are not conversation. A parser that treated any
// 'payload' as a message would surface the session's own metadata as a turn.
ok(!codex.some(m => JSON.stringify(m).includes('codex_cli')),
   'the session_meta line does not become a message')

// A developer/system message is the agent's scaffolding, not the conversation.
const codexSystem = parseTranscriptFor('codex', JSON.stringify({ type: 'response_item',
  payload: { type: 'message', role: 'developer', content: [{ type: 'input_text', text: 'be terse' }] } }))
ok(codexSystem.length === 0, 'a Codex developer message stays out of the conversation')

// An item type this build has not seen is dropped, not guessed at.
const codexUnknown = parseTranscriptFor('codex', JSON.stringify({ type: 'response_item',
  payload: { type: 'some_future_item', text: 'hello' } }))
ok(codexUnknown.length === 0, 'an unknown Codex item type is dropped')

// An image input contributes nothing, for the same reason a Claude image does.
const codexImage = parseTranscriptFor('codex', JSON.stringify({ type: 'response_item',
  payload: { type: 'message', role: 'user', content: [
    { type: 'input_text', text: 'look' },
    { type: 'input_image', image_url: 'data:image/png;base64,' + 'A'.repeat(50000) } ] } }))
ok(codexImage[0].blocks.length === 1 && codexImage[0].blocks[0].text === 'look',
   'a Codex image input contributes nothing to the text')

// The same guarantees the Claude parser gives: garbage and a half-written tail
// never throw.
ok(parseTranscriptFor('codex', 'not json').length === 0, 'garbage is dropped by the Codex parser too')
ok(parseTranscriptFor('codex', codexLines + '\n{\"type\":\"response').length === 5,
   'a truncated final Codex line still leaves the rest readable')

// MARK: - The capture
//
// Everything above is the documented shape. This is the other half: a rollout
// captured from a real '~/.codex/sessions' tree (Codex CLI 0.162.1, 2026-10-13),
// trimmed to eight records and otherwise byte-exact. The one edit is the removal
// of session_meta's 'base_instructions' — the agent's whole system prompt, which
// is neither small nor portable — and nothing was rewritten. The reader carried
// an UNVERIFIED note until this existed.
//
// What the capture settles is that the field names the parser keys on are the
// ones Codex actually writes: reasoning summaries under 'summary', a tool's
// arguments as a JSON *string*, the output paired by 'call_id', and three record
// types that are not conversation at all.

const captured = readFileSync('$FIXTURE', 'utf8')
const real = parseTranscriptFor('codex', captured)

ok(real.length === 6, 'the capture reads as six messages from eight records (got ' + real.length + ')')
ok(real.map(m => m.role).join(',') === 'user,user,assistant,assistant,tool,assistant',
   'and in the roles it holds (got ' + real.map(m => m.role).join(',') + ')')
ok(real[0].blocks[0].kind === 'text' && real[0].blocks[0].text.startsWith('<environment_context>'),
   'the environment context is the user speaking, verbatim')
ok(real[1].blocks[0].text === '\u8bfb\u4e00\u4e0b\u4e4b\u524dclaude code\u7684\u5f00\u53d1\u8bb0\u5f55\uff0c\u7136\u540e\u7531\u4f60\u63a5\u624bAppFolder',
   'and the real prompt survives byte for byte')
ok(real[3].blocks[0].kind === 'tool' && real[3].blocks[0].name === 'exec_command',
   'a captured exec_command is a tool block')
ok(typeof real[3].blocks[0].input === 'string' && real[3].blocks[0].input.startsWith('{'),
   'with its arguments still a JSON string, not an object')
ok(JSON.parse(real[3].blocks[0].input).cmd === 'ls -la /Users/lvyufeng/Projects/AppFolder',
   'and the command inside it is the one that ran')
ok(real[4].blocks[0].kind === 'result' && real[4].blocks[0].id === real[3].blocks[0].id,
   'the output is paired with the call by call_id')
ok(real[5].blocks[0].kind === 'thinking' && real[5].blocks[0].text.startsWith('Let me look at the .claude'),
   'and a captured reasoning summary is thinking, not the answer')
ok(!real.some(m => JSON.stringify(m).includes('turn_token_usage')),
   'a token_usage_record does not become a message')
ok(!real.some(m => JSON.stringify(m).includes('base_instructions')),
   'nor does the session_meta')

// MARK: - Finding the right agent's log, on disk
//
// The registry has to choose *which* agent's session a directory is talking
// about, from real files. These build a throwaway HOME with one Claude project
// tree and one Codex rollout tree and read them back through 'readTranscript'.

const home = mkdtempSync(join(tmpdir(), 'cqutmux-transcript-'))
const project = '/work/demo'

try {
  // Claude Code: ~/.claude/projects/<slug>/<session>.jsonl
  const claudeDir = claudeProjectDir(project, home)
  mkdirSync(claudeDir, { recursive: true })
  const claudePath = join(claudeDir, '8f14e45f-ceea-467a-9d0a-2b1c3d4e5f60.jsonl')
  writeFileSync(claudePath, JSON.stringify({ type: 'user', uuid: 'u1',
    message: { role: 'user', content: 'from claude' } }))

  // Codex: ~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<id>.jsonl
  const codexDir = join(home, '.codex', 'sessions', '2026', '01', '01')
  mkdirSync(codexDir, { recursive: true })
  const codexPath = join(codexDir, 'rollout-2026-01-01T00-00-00-abcdef01-2345-6789-abcd-ef0123456789.jsonl')
  writeFileSync(codexPath, [
    JSON.stringify({ timestamp: '2026-01-01T00:00:00Z', type: 'session_meta',
      payload: { id: 't1', cwd: project } }),
    JSON.stringify({ timestamp: '2026-01-01T00:00:01Z', type: 'response_item',
      payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'from codex' }] } }),
  ].join('\n'))

  // The slug directory is built from the project path, so the reader finds the
  // Claude tree without a scan. Exported so this check does not restate the rule.
  ok(claudeDir.endsWith('projects/-work-demo'), 'the Claude project slug is derived from the path')

  // Claude's log is newer: the reader must name Claude Code and its session.
  const now = Date.now()
  utimesSync(codexPath, new Date(now - 10000), new Date(now - 10000))
  utimesSync(claudePath, new Date(now), new Date(now))

  const claudePick = await readTranscript(project, 200, home)
  ok(claudePick.found === true, 'the newest log is found across agents')
  ok(claudePick.agent === 'claude-code', 'the Claude log reports its agent (got ' + claudePick.agent + ')')
  ok(claudePick.session === '8f14e45f', 'and a short session id (got ' + claudePick.session + ')')
  ok(claudePick.messages[0].blocks[0].text === 'from claude', 'with the Claude message')
  // The pre-existing wire fields are untouched: an older app still decodes this.
  ok(claudePick.file === '8f14e45f-ceea-467a-9d0a-2b1c3d4e5f60.jsonl'
     && claudePick.total === 1,
     'the file and total fields the app already reads are unchanged')

  // Codex's rollout is newer now: it must win, and be named as Codex.
  utimesSync(claudePath, new Date(now - 20000), new Date(now - 20000))
  utimesSync(codexPath, new Date(now), new Date(now))

  const codexPick = await readTranscript(project, 200, home)
  ok(codexPick.found === true && codexPick.agent === 'codex',
     'the newer Codex rollout wins and is named (got ' + codexPick.agent + ')')
  ok(codexPick.messages[0].blocks[0].text === 'from codex', 'with the Codex message')
  ok(codexPick.session === 'abcdef01', 'and the Codex session id from its filename (got ' + codexPick.session + ')')

  // The capture, put where Codex would have written it, with the cwd its
  // session_meta recorded. That path is only ever compared as a string — the
  // reader never resolves it — so this holds on a machine that has no such
  // directory, which is what makes a real capture usable as a fixture.
  const capturedDir = join(home, '.codex', 'sessions', '2026', '10', '13')
  mkdirSync(capturedDir, { recursive: true })
  writeFileSync(join(capturedDir,
    'rollout-2026-10-13T20-20-19-01a13534-df73-7390-a72f-1742ebc12973.jsonl'), captured)
  const capturedPick = await readTranscript('/Users/lvyufeng/Projects/AppFolder', 200, home)
  ok(capturedPick.found === true && capturedPick.agent === 'codex',
     'the capture is found by the cwd its session_meta recorded (got ' + capturedPick.agent + ')')
  ok(capturedPick.session === '01a13534',
     'and named by its real filename\'s thread id (got ' + capturedPick.session + ')')
  ok(capturedPick.total === 6, 'with all six of its messages (got ' + capturedPick.total + ')')

  // A Codex rollout whose recorded cwd is a different project must not be
  // offered as this directory's session — the cwd is the only project link.
  const otherCodex = join(codexDir, 'rollout-2026-01-02T00-00-00-deadbeef-2345-6789-abcd-ef0123456789.jsonl')
  writeFileSync(otherCodex, JSON.stringify({ timestamp: '2026-01-02T00:00:00Z', type: 'session_meta',
    payload: { id: 't2', cwd: '/work/somewhere-else' } }))
  utimesSync(otherCodex, new Date(now + 10000), new Date(now + 10000))
  const stillCodex = await readTranscript(project, 200, home)
  ok(stillCodex.session === 'abcdef01',
     'a Codex rollout for another directory is not this directory\\'s session (got ' + stillCodex.session + ')')

  // No log for the directory at all degrades to 'no session', not an error.
  const none = await readTranscript('/work/never-used', 200, home)
  ok(none.found === false && none.messages.length === 0,
     'a directory with no session reads as no session')
} finally {
  rmSync(home, { recursive: true, force: true })
}

console.log('')
console.log('TRANSCRIPT_PASS  (' + pass + ' checks)')
" || fail "the transcript reader did not pass its checks"

printf '\nTRANSCRIPT_OK\n'
