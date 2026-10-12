// Reading an agent's session transcript as a conversation.
//
// A coding agent already writes a raw session log to disk — Claude Code keeps
// one JSONL per session under `~/.claude/projects/<slug>/`, Codex keeps rollout
// JSONL under `~/.codex/sessions/YYYY/MM/DD/`. Each format is internal and
// changes between releases, so this file's job is to be the one place that
// knows them: forgiving about what it does not recognise, strict about never
// throwing, because a parse failure here must degrade to "no chat" rather than
// to "the app is broken".
//
// Every agent is one entry in `READERS`: how to find its newest log for a
// project directory, how to turn one of its records into a message, and how to
// read a short session id out of its filename. Adding an agent is adding an
// entry, not threading another `if` through a shared parser — the formats have
// nothing in common but the shape of the output, and a parser that tried to
// hold both would get the one it does not know wrong in silence.
//
// The transcript is the source of truth, not the terminal. Reading the log
// rather than scraping the pane is what makes a tool call render as a tool
// card with its own input and output, instead of as the ANSI-coloured text a
// terminal happened to have on screen.

import { open, readFile, readdir, stat } from 'fs/promises'
import { join } from 'path'

/** How much of one tool result to keep. Results include whole files. */
const MAX_RESULT = 4000
const MAX_TEXT = 8000
/** How many log files a discovery walk will look at before giving up. */
const MAX_SCAN_FILES = 200
/** How much of a file to read looking for the working directory it records. */
const HEAD_BYTES = 65536

// MARK: - Shared reading helpers
//
// These are format-neutral: they know nothing about which agent wrote the
// record, only about what a message's text is allowed to be.

function clamp(text, limit) {
  const trimmed = String(text || '').trim()
  if (trimmed.length <= limit) return trimmed
  // Say how much was cut rather than trailing off: a truncated result that
  // looks complete is worse than one that admits it.
  return trimmed.slice(0, limit) + `\n… (${trimmed.length - limit} more characters)`
}

function safeStringify(value) {
  try {
    return clamp(JSON.stringify(value, null, 2) ?? '', MAX_TEXT)
  } catch {
    return ''
  }
}

/**
 * A tool result's content is either a string or a list of blocks. Only the
 * text is useful here: an image block in a transcript is a base64 payload
 * megabytes long, and shipping it to a phone to render a chat line is not a
 * trade worth making.
 */
function flattenResult(content) {
  if (typeof content === 'string') return clamp(content, MAX_RESULT)
  if (!Array.isArray(content)) return ''
  const parts = []
  for (const piece of content) {
    if (typeof piece === 'string') parts.push(piece)
    else if (piece && typeof piece === 'object' && typeof piece.text === 'string') parts.push(piece.text)
  }
  return clamp(parts.join('\n'), MAX_RESULT)
}

/**
 * The token counts on an assistant turn, as numbers.
 *
 * Passed through wholesale rather than picked apart here: the key set belongs
 * to the agent and drifts between releases, and the app's `ContextWindow` reads
 * only the four it knows. Numbers only — a string where a count is expected
 * would be carried to the phone and then summed as zero, which reads as an
 * empty context window rather than as a malformed field.
 */
function numericUsage(usage) {
  if (!usage || typeof usage !== 'object' || Array.isArray(usage)) return null
  const out = {}
  for (const [key, value] of Object.entries(usage)) {
    if (typeof value === 'number' && Number.isFinite(value)) out[key] = value
  }
  return Object.keys(out).length ? out : null
}

/** The last path component, for reading an id out of a filename. */
function baseName(file) {
  return String(file || '').split(/[/\\]/).pop() || ''
}

/** A short session id: the first eight characters are enough to tell two apart. */
function shortId(id) {
  if (!id) return null
  return id.length > 8 ? id.slice(0, 8) : id
}

/** The bytes at the start of a file, as text, or '' — never throws. */
async function head(path, bytes = HEAD_BYTES) {
  let handle
  try {
    handle = await open(path, 'r')
    const buffer = Buffer.alloc(bytes)
    const { bytesRead } = await handle.read(buffer, 0, bytes, 0)
    return buffer.subarray(0, bytesRead).toString('utf8')
  } catch {
    return ''
  } finally {
    try { await handle?.close() } catch { /* already gone */ }
  }
}

/** Every `*.jsonl` under `dir`, recursively, with its mtime. Depth-limited and
 *  capped: this walks a directory we do not own. */
async function jsonlFiles(dir, depth = 0, found = []) {
  if (depth > 4 || found.length >= MAX_SCAN_FILES) return found
  let entries
  try {
    entries = await readdir(dir, { withFileTypes: true })
  } catch {
    return found
  }
  // Newest first, and this is load-bearing rather than tidiness: the cap stops
  // the walk wherever it happens to land, so the order entries are visited in
  // decides which files survive it. `readdir`'s own order is the filesystem's
  // business — on APFS it is not sorted — so without this the cap keeps an
  // arbitrary `MAX_SCAN_FILES` and a rollout written a minute ago can lose its
  // place to one from last year. The name order is a time order at both levels
  // of Codex's layout: `sessions/YYYY/MM/DD/` and
  // `rollout-<19-char timestamp>-<id>.jsonl`.
  entries.sort((a, b) => b.name.localeCompare(a.name))
  for (const entry of entries) {
    if (found.length >= MAX_SCAN_FILES) break
    const path = join(dir, entry.name)
    if (entry.isDirectory()) {
      await jsonlFiles(path, depth + 1, found)
    } else if (entry.name.endsWith('.jsonl')) {
      try {
        const info = await stat(path)
        found.push({ path, name: entry.name, mtimeMs: info.mtimeMs })
      } catch {
        continue
      }
    }
  }
  return found
}

/** The working directory a JSONL head records, or null. */
function cwdFromHead(text) {
  for (const line of String(text || '').split('\n')) {
    const trimmed = line.trim()
    if (!trimmed || trimmed[0] !== '{') continue
    let record
    try {
      record = JSON.parse(trimmed)
    } catch {
      continue
    }
    const cwd = record?.cwd || record?.payload?.cwd
    if (typeof cwd === 'string' && cwd.startsWith('/')) return cwd
  }
  return null
}

// MARK: - Claude Code

/**
 * A block that is not recognised is dropped, not guessed at.
 */
function claudeBlock(raw) {
  if (!raw || typeof raw !== 'object') return null
  switch (raw.type) {
    case 'text':
      return typeof raw.text === 'string' && raw.text.trim()
        ? { kind: 'text', text: raw.text.trim() }
        : null
    case 'thinking':
      // Kept, and marked. An agent's reasoning is part of what it is doing and
      // Moshi shows it; folding it into the answer text would present a guess
      // as a conclusion.
      return typeof raw.thinking === 'string' && raw.thinking.trim()
        ? { kind: 'thinking', text: raw.thinking.trim() }
        : null
    case 'tool_use':
      return {
        kind: 'tool',
        id: raw.id || '',
        name: raw.name || 'tool',
        // The input is the interesting part of a tool call and it is
        // structured; it is carried through as JSON text so the app decides
        // how to render each shape.
        input: safeStringify(raw.input),
      }
    case 'tool_result': {
      const text = flattenResult(raw.content)
      return text
        ? { kind: 'result', id: raw.tool_use_id || '', text, isError: raw.is_error === true }
        : null
    }
    default:
      return null
  }
}

/**
 * One JSONL line to one message, or null when the line is not a message.
 *
 * Tool results arrive as `user` records whose content is a result block — the
 * agent protocol's own shape, not a person speaking. Returning them as their
 * own message kind keeps "the user said this" distinct from "the tool printed
 * this", which is the distinction the chat view is built around.
 */
function claudeMessage(record) {
  if (!record || typeof record !== 'object') return null
  const type = record.type
  if (type !== 'user' && type !== 'assistant') return null
  if (record.isSidechain === true) return null

  const content = record.message?.content
  const blocks = []
  if (typeof content === 'string') {
    if (content.trim()) blocks.push({ kind: 'text', text: content.trim() })
  } else if (Array.isArray(content)) {
    for (const raw of content) {
      const parsed = claudeBlock(raw)
      if (parsed) blocks.push(parsed)
    }
  }
  if (!blocks.length) return null

  const onlyResults = blocks.every(b => b.kind === 'result')
  return {
    id: record.uuid || `${type}-${blocks.length}`,
    role: onlyResults ? 'tool' : type,
    at: record.timestamp || null,
    blocks,
    model: record.message?.model || null,
    usage: numericUsage(record.message?.usage),
  }
}

/**
 * The directory Claude Code keeps one project's sessions in.
 *
 * The slug is the working directory's path with separators replaced, which is
 * lossy (`/srv/a-b` and `/srv/a/b` collide) — but for *reading a session* that
 * only matters when two projects share a slug, and the alternative (scanning
 * every project's every session for a matching `cwd`) costs a walk of the whole
 * home directory on every poll. Exported so a check can build the same tree the
 * reader looks in without restating the rule.
 */
export function claudeProjectDir(projectDir, home = process.env.HOME || '') {
  const slug = '-' + String(projectDir).replace(/^[/\\]/, '').replace(/[/\\]/g, '-')
  return join(home, '.claude', 'projects', slug)
}

const claudeReader = {
  id: 'claude-code',
  label: 'Claude Code',

  /**
   * The newest transcript for a project directory.
   *
   * Claude Code names the file `<session-id>.jsonl` inside a directory derived
   * from the working directory's path. The newest file is the running session
   * in all but the case where several agents share a project; picking the
   * newest is a heuristic, and the alternative — asking the agent which session
   * it is — is not available from outside the process.
   */
  async newest(projectDir, home = process.env.HOME || '') {
    const dir = claudeProjectDir(projectDir, home)
    let entries
    try {
      entries = await readdir(dir)
    } catch {
      return null
    }
    let newest = null
    for (const name of entries) {
      if (!name.endsWith('.jsonl')) continue
      const path = join(dir, name)
      try {
        const info = await stat(path)
        if (!newest || info.mtimeMs > newest.mtimeMs) {
          newest = { path, name, mtimeMs: info.mtimeMs }
        }
      } catch {
        continue
      }
    }
    if (!newest) return null
    return { ...newest, dir }
  },

  message: claudeMessage,

  /** `<session-uuid>.jsonl` — the uuid's first eight characters. */
  session(file) {
    const base = baseName(file)
    if (!base) return null
    const core = base.endsWith('.jsonl') ? base.slice(0, -'.jsonl'.length) : base
    return shortId(core)
  },
}

// MARK: - Codex
//
// UNVERIFIED: this reader is written from openai/codex's public source — the
// `ResponseItem` and `RolloutItem` types in `codex-rs/protocol/src/models.rs`
// and `codex-rs/history/src/rollout_payload.rs`, and the session layout in
// `codex-rs/rollout/src/list.rs` — and has **not** been run against a real
// rollout file. This machine has no `~/.codex/sessions` tree to test against,
// so every field name below is a documented claim, not an observed one.
//
// What would verify it: a real `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
// captured from a Codex CLI run that used at least one tool, kept as a fixture
// and fed through `parseTranscriptFor('codex', …)`. Until then this is
// best-effort: a shape it does not recognise is dropped, and a tree that is not
// there contributes nothing.
//
// A rollout line is `{ timestamp, type, payload }`. The conversation lives in
// lines whose `type` is `response_item`, and the item inside carries its own
// `type` — `message`, `reasoning`, `function_call`, `function_call_output`,
// `custom_tool_call`, `local_shell_call`, and others.

function codexTextBlocks(content) {
  const blocks = []
  for (const piece of Array.isArray(content) ? content : []) {
    if (!piece || typeof piece !== 'object') continue
    // `input_text` and `output_text` both carry a plain `text`. Anything else
    // (an image, an audio clip, an encrypted blob) contributes nothing, for the
    // same reason Claude's image blocks do not.
    if (typeof piece.text === 'string' && piece.text.trim()) {
      blocks.push({ kind: 'text', text: piece.text.trim() })
    }
  }
  return blocks
}

function codexMessage(record) {
  if (!record || typeof record !== 'object') return null
  if (record.type !== 'response_item') return null
  const item = record.payload
  if (!item || typeof item !== 'object') return null
  const at = typeof record.timestamp === 'string' ? record.timestamp : null

  switch (item.type) {
    case 'message': {
      // Only the two voices the chat view draws. A `developer` or `system`
      // message is the agent's own scaffolding, not the conversation.
      if (item.role !== 'user' && item.role !== 'assistant') return null
      const blocks = codexTextBlocks(item.content)
      if (!blocks.length) return null
      return {
        id: item.id || `codex-${item.role}-${blocks.length}`,
        role: item.role,
        at,
        blocks,
        model: null,
        usage: null,
      }
    }
    case 'reasoning': {
      const parts = []
      for (const piece of Array.isArray(item.summary) ? item.summary : []) {
        if (piece && typeof piece.text === 'string' && piece.text.trim()) parts.push(piece.text.trim())
      }
      if (!parts.length) return null
      return {
        id: item.id || 'codex-reasoning',
        role: 'assistant',
        at,
        blocks: [{ kind: 'thinking', text: parts.join('\n') }],
        model: null,
        usage: null,
      }
    }
    case 'function_call':
    case 'custom_tool_call': {
      const args = item.arguments ?? item.input
      return {
        id: item.call_id || item.id || 'codex-tool',
        role: 'assistant',
        at,
        blocks: [{
          kind: 'tool',
          id: item.call_id || item.id || '',
          name: item.name || 'tool',
          // `arguments` is a JSON *string* (the Responses API returns it that
          // way) and is carried through as-is so the app can parse it; a
          // structured `input` is stringified.
          input: typeof args === 'string' ? clamp(args, MAX_TEXT) : safeStringify(args),
        }],
        model: null,
        usage: null,
      }
    }
    case 'function_call_output':
    case 'custom_tool_call_output': {
      const text = flattenResult(item.output)
      if (!text) return null
      return {
        id: item.call_id || item.id || 'codex-result',
        role: 'tool',
        at,
        // The item carries an internal `success` flag that is not part of the
        // serialized body, so a failure cannot be read off the wire here; the
        // app shows it as an ordinary result rather than guessing.
        blocks: [{ kind: 'result', id: item.call_id || '', text, isError: false }],
        model: null,
        usage: null,
      }
    }
    case 'local_shell_call': {
      const command = item.action?.command
      const text = Array.isArray(command) ? command.join(' ') : (typeof command === 'string' ? command : '')
      if (!text.trim()) return null
      return {
        id: item.call_id || item.id || 'codex-shell',
        role: 'assistant',
        at,
        blocks: [{ kind: 'tool', id: item.call_id || '', name: 'shell', input: safeStringify(command) }],
        model: null,
        usage: null,
      }
    }
    default:
      return null
  }
}

const codexReader = {
  id: 'codex',
  label: 'Codex',

  /**
   * The newest rollout for a project directory.
   *
   * Codex does not organise sessions by project: every rollout lands under
   * `~/.codex/sessions/YYYY/MM/DD/` and the working directory is recorded in
   * the `session_meta` line inside the file. So the only way to find a
   * directory's session is to read the head of the recent rollouts and match
   * the `cwd` — bounded and newest-first, so the common case reads one file.
   * Best-effort by construction: a project whose session is older than the cap
   * reads as "no session", which is the same answer as an agent that never ran.
   */
  async newest(projectDir, home = process.env.HOME || '') {
    const root = join(home, '.codex', 'sessions')
    const files = await jsonlFiles(root)
    // Newest first, so the first file whose cwd matches is the answer without
    // reading the rest.
    files.sort((a, b) => b.mtimeMs - a.mtimeMs)
    for (const file of files) {
      const cwd = cwdFromHead(await head(file.path))
      if (cwd !== projectDir) continue
      return { ...file, dir: root }
    }
    return null
  },

  message: codexMessage,

  /**
   * `rollout-<timestamp>-<thread-id>.jsonl`, where the timestamp is a
   * 19-character `YYYY-MM-DDThh-mm-ss`. A reverted thread appends `_<rollout-id>`
   * after the thread id; the header wants the thread, so the part before `_`.
   */
  session(file) {
    const base = baseName(file)
    if (!base) return null
    const core = base.endsWith('.jsonl') ? base.slice(0, -'.jsonl'.length) : base
    if (!core.startsWith('rollout-')) return shortId(core)
    const rest = core.slice('rollout-'.length)
    // 19-char timestamp, then '-', then the id.
    const afterStamp = rest.length > 20 ? rest.slice(20) : rest
    return shortId(afterStamp.split('_')[0])
  },
}

/** Every agent this reader understands, Claude Code first. */
const READERS = [claudeReader, codexReader]

// MARK: - The registry's public surface

/** The ids of the agents this reader knows, in preference order. */
export function agentIds() {
  return READERS.map(reader => reader.id)
}

/** The reader with this id, or null. */
function readerFor(id) {
  return READERS.find(reader => reader.id === id) || null
}

/**
 * Parses a whole transcript file's text for one agent. Never throws.
 *
 * The agent is named rather than sniffed: a Claude Code record and a Codex
 * record can both be valid JSON objects with a `type`, and the parsers disagree
 * about what that means. Guessing would silently read one agent's log with the
 * other's rules.
 */
export function parseTranscriptFor(id, text) {
  const reader = readerFor(id)
  if (!reader) return []
  const messages = []
  for (const line of String(text).split('\n')) {
    const trimmed = line.trim()
    if (!trimmed) continue
    let record
    try {
      record = JSON.parse(trimmed)
    } catch {
      // A half-written last line is normal while an agent is running: the file
      // is being appended to as we read it. Skipping is correct.
      continue
    }
    let message
    try {
      message = reader.message(record)
    } catch {
      // A parser is not allowed to take the gateway down with it. An unexpected
      // shape degrades to "this line said nothing".
      message = null
    }
    if (message) messages.push(message)
  }
  return messages
}

/** Parses a Claude Code transcript file's text. Never throws. */
export function parseTranscript(text) {
  return parseTranscriptFor(claudeReader.id, text)
}

/** The newest Claude Code transcript for a directory, or null. */
export async function newestTranscript(projectDir, home = process.env.HOME || '') {
  return claudeReader.newest(projectDir, home)
}

/**
 * Reads and parses the newest transcript for a directory, across every agent.
 *
 * Returns the message tail plus which agent wrote it and its short session id.
 * `agent` and `session` are additive: an older app that does not read them
 * still decodes the page, and the app that does can name the agent in its
 * header instead of assuming Claude Code.
 */
export async function readTranscript(projectDir, limit = 200, home = process.env.HOME || '') {
  const candidates = []
  for (const reader of READERS) {
    let found = null
    try {
      found = await reader.newest(projectDir, home)
    } catch {
      found = null
    }
    if (found) candidates.push({ reader, found })
  }
  if (!candidates.length) return { found: false, messages: [] }

  // The newest log wins. Within one agent that is the running session; across
  // agents it is the one most recently written, which is the same heuristic
  // applied one level up.
  candidates.sort((a, b) => b.found.mtimeMs - a.found.mtimeMs)
  const { reader, found } = candidates[0]

  let text
  try {
    text = await readFile(found.path, 'utf8')
  } catch {
    return { found: false, messages: [] }
  }
  const all = parseTranscriptFor(reader.id, text)
  // The tail is what a phone wants: a long session is thousands of messages
  // and the interesting end is the newest.
  return {
    found: true,
    agent: reader.id,
    file: found.name,
    session: reader.session(found.name),
    total: all.length,
    messages: all.slice(-limit),
  }
}
