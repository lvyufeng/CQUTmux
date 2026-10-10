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
// Usage: agent-hook.mjs <source> <approval|notice|session-start|tool-finish>
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

// Which of Moshi's five categories this is.
//
// The agent's own event name is the best evidence, because a payload says which
// event fired; the kind we were invoked with is the fallback, for an agent that
// sends no event name or an install that predates this table. The Inbox derives
// the same value from the kind when the field is missing, so a category is a
// refinement that must never contradict the shape — `notice` for a tool's end
// is still a notice, not an approval.
const eventName = pick(payload, ['hook_event_name', 'hookEventName', 'event'])
const CATEGORY_OF_EVENT = {
  PreToolUse: 'approval_required',
  PostToolUse: 'tool_finished',
  Stop: 'task_complete',
  SessionStart: 'session_started',
  SessionEnd: 'task_complete',
}
const CATEGORY_OF_KIND = {
  approval: 'approval_required',
  'session-start': 'session_started',
  'tool-finish': 'tool_finished',
  notice: 'task_complete',
}
const category = CATEGORY_OF_EVENT[eventName] || CATEGORY_OF_KIND[kind] || 'task_complete'

// Two readers of the same fact: a category that only describes the end of a
// turn is a turn summary, and every other category is about a tool that is
// named in the payload. Reading the title off the *category* rather than off
// the kind is what keeps `tool_finished` from being announced as "Task
// finished" — both arrive as a `notice` on the wire.
const title = category === 'task_complete'
  ? 'Task finished'
  : (typeof tool === 'string' && tool) || 'tool call'
const body = category === 'task_complete' ? flatten(message) : flatten(detail)

const cwd = pick(payload, ['cwd', 'workspace', 'working_directory', 'workingDirectory'])
const model = pick(payload, ['model', 'model_name', 'modelName'])

const event = {
  source,
  kind,
  category,
  title: String(title).slice(0, 200),
  body: body.slice(0, 1000),
  data: {
    ...(session ? { session: String(session) } : {}),
    ...(cwd ? { cwd: String(cwd) } : {}),
    ...(model ? { model: String(model) } : {}),
    // The agent's own event name, kept so a future hook can be told apart from
    // an old one without the gateway guessing from the fields present.
    ...(eventName ? { event: String(eventName) } : {}),
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