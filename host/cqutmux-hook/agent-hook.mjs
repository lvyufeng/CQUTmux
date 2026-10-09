#!/usr/bin/env node
// One bridge for the agents that speak stdin-JSON hooks.
//
// Claude Code, Codex, Cursor, Kimi Code and Antigravity all hand a command hook
// a JSON object on stdin and let it decide nothing about the payload's shape —
// but each names the same few fields differently (`tool_name` vs `toolName`,
// `session_id` vs `conversation_id`, `last_assistant_message` vs
// `last_assistant_message`). This reads whichever it was given and posts one
// event to the gateway.
//
// The alternative — a bridge script per agent — would be five copies of the
// same curl, five places to fix when the gateway's event shape moves, and five
// chances for one of them to be subtly different. The differences here are
// exactly the field names, so they live in a table.
//
// Usage: agent-hook.mjs <source> <approval|notice>
//
// Never blocks the agent: any failure exits 0. A hook that errors is far worse
// than a missing notification, because the agent waits on it.

import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const [, , source = 'unknown', kind = 'notice'] = process.argv

const PORT = process.env.CQUTMUX_PORT || '24543'
const URL_ENDPOINT = `http://127.0.0.1:${PORT}/events`

/**
 * The gateway's token, if it has one.
 *
 * A gateway started with `--token` rejects anything without the header, and the
 * agent spawns this hook with none of our environment — so without this the
 * event is refused with a 401 that nobody sees and the inbox stays empty while
 * the hooks look correctly installed. The gateway publishes the token to
 * `~/.cqutmux/token` for exactly this; CQUTMUX_TOKEN is honoured first so a
 * hand-run bridge can be pointed somewhere else.
 */
function gatewayToken() {
  if (process.env.CQUTMUX_TOKEN) return process.env.CQUTMUX_TOKEN
  try {
    return readFileSync(join(homedir(), '.cqutmux', 'token'), 'utf8').trim()
  } catch {
    return ''
  }
}

/** Reads stdin to the end. Empty stdin yields an empty object, not an error:
 *  a hook invoked without a payload is a configuration mistake, and the
 *  notification is simply less informative rather than fatal. */
async function readStdin() {
  const chunks = []
  for await (const chunk of process.stdin) chunks.push(chunk)
  const text = Buffer.concat(chunks).toString('utf8').trim()
  if (!text) return {}
  try {
    const parsed = JSON.parse(text)
    return parsed && typeof parsed === 'object' ? parsed : {}
  } catch {
    return {}
  }
}

/** First present value among several spellings. */
function pick(object, names) {
  for (const name of names) {
    const value = object?.[name]
    if (typeof value === 'string' && value) return value
    if (value && typeof value === 'object') return value
  }
  return undefined
}

/** A short, single-line rendering of whatever the agent attached. */
function flatten(value) {
  if (value === undefined || value === null) return ''
  const text = typeof value === 'string' ? value : JSON.stringify(value)
  return text.replace(/\s+/g, ' ').slice(0, 1000)
}

const payload = await readStdin()

const session = pick(payload, [
  'session_id', 'conversation_id', 'conversationId', 'thread_id', 'threadId',
  'sessionId', 'session',
])

// Field names differ per agent and per event, so each slot lists every spelling
// seen in the documented payloads rather than branching per source. A hook that
// grows a new event with a different name keeps working as long as it says what
// the tool was somewhere.
const tool = pick(payload, ['tool_name', 'toolName', 'name', 'tool'])
const detail = pick(payload, ['tool_input', 'toolInput', 'input', 'arguments', 'args'])

// Turn-complete bodies. `input-messages` is Codex's `notify` field; the rest
// are the transcript-message names the others use.
const message = pick(payload, [
  'last_assistant_message', 'lastAssistantMessage', 'last-assistant-message',
  'message', 'response', 'summary',
])

const title = kind === 'approval'
  ? (typeof tool === 'string' && tool) || 'tool call'
  : 'Task finished'
const body = kind === 'approval' ? flatten(detail) : flatten(message)

const cwd = pick(payload, ['cwd', 'workspace', 'working_directory', 'workingDirectory'])
const model = pick(payload, ['model', 'model_name', 'modelName'])

const event = {
  source,
  kind,
  title: String(title).slice(0, 200),
  body: body.slice(0, 1000),
  data: {
    ...(session ? { session: String(session) } : {}),
    ...(cwd ? { cwd: String(cwd) } : {}),
    ...(model ? { model: String(model) } : {}),
    // The agent's own event name, kept so a future hook can be told apart from
    // an old one without the gateway guessing from the fields present.
    ...(pick(payload, ['hook_event_name', 'hookEventName', 'event'])
      ? { event: String(pick(payload, ['hook_event_name', 'hookEventName', 'event'])) }
      : {}),
  },
}

try {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 2000)
  const token = gatewayToken()
  await fetch(URL_ENDPOINT, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(event),
    signal: controller.signal,
  })
  clearTimeout(timer)
} catch {
  // Best effort, as above.
}

process.exit(0)