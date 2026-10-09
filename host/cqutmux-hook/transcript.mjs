// Reading an agent's session transcript as a conversation.
//
// A coding agent already writes a raw session log to disk — Claude Code keeps
// one JSONL per session under `~/.claude/projects/<slug>/`. Its format is
// internal and it changes between releases, so this file's job is to be the
// one place that knows it: forgiving about what it does not recognise, strict
// about never throwing, because a parse failure here must degrade to "no chat"
// rather than to "the app is broken".
//
// The transcript is the source of truth, not the terminal. Reading the log
// rather than scraping the pane is what makes a tool call render as a tool
// card with its own input and output, instead of as the ANSI-coloured text a
// terminal happened to have on screen.

import { readFile, readdir, stat } from 'fs/promises'
import { join } from 'path'

/** How much of one tool result to keep. Results include whole files. */
const MAX_RESULT = 4000
const MAX_TEXT = 8000

/** A block that is not recognised is dropped, not guessed at. */
function block(raw) {
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
 * One JSONL line to one message, or null when the line is not a message.
 *
 * Tool results arrive as `user` records whose content is a result block — the
 * agent protocol's own shape, not a person speaking. Returning them as their
 * own message kind keeps "the user said this" distinct from "the tool printed
 * this", which is the distinction the chat view is built around.
 */
export function messageFromRecord(record) {
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
      const parsed = block(raw)
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
  }
}

/** Parses a whole transcript file's text. Never throws. */
export function parseTranscript(text) {
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
    const message = messageFromRecord(record)
    if (message) messages.push(message)
  }
  return messages
}

/**
 * The newest transcript for a project directory.
 *
 * Claude Code names the file `<session-id>.jsonl` inside a directory derived
 * from the working directory's path with separators replaced. The newest file
 * is the running session in all but the case where several agents share a
 * project; picking the newest is a heuristic, and the alternative — asking the
 * agent which session it is — is not available from outside the process.
 */
export async function newestTranscript(projectDir) {
  const slug = '-' + String(projectDir).replace(/^[/\\]/, '').replace(/[/\\]/g, '-')
  const dir = join(process.env.HOME || '', '.claude', 'projects', slug)
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
        newest = { path, mtimeMs: info.mtimeMs, name }
      }
    } catch {
      continue
    }
  }
  if (!newest) return null
  return { ...newest, dir }
}

/** Reads and parses the newest transcript for a directory. */
export async function readTranscript(projectDir, limit = 200) {
  const found = await newestTranscript(projectDir)
  if (!found) return { found: false, messages: [] }
  let text
  try {
    text = await readFile(found.path, 'utf8')
  } catch {
    return { found: false, messages: [] }
  }
  const all = parseTranscript(text)
  // The tail is what a phone wants: a long session is thousands of messages
  // and the interesting end is the newest.
  return { found: true, file: found.name, total: all.length, messages: all.slice(-limit) }
}