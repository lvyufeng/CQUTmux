// Finding the directories an agent has recently been working in.
//
// The app can only report the directories *it* has browsed, which is a small
// and unhelpful set: the paths a user wants back are the ones their agents ran
// in, and those were opened from a terminal, not from here. So this reads the
// agents' own on-disk history.
//
// Every agent keeps this differently and all of the formats are internal:
//
//   Claude Code   ~/.claude/projects/<slug>/<session>.jsonl, where the slug is
//                 the working directory with separators replaced by dashes
//   Codex         ~/.codex/sessions/**/*.jsonl, with a cwd in the records
//   Cursor        ~/.cursor/…, and its CLI stores projects differently again
//
// The slug is the awkward one, because it is lossy: `/srv/a-b` and `/srv/a/b`
// both become `-srv-a-b`, so a path cannot be recovered from the directory name
// alone. Rather than guess, this reads the transcript records — Claude Code
// writes a `cwd` into each line — and falls back to the slug only when a line
// has none, marking the entry as inferred so the app can say which is which.
//
// Everything here is best-effort and silent. A host with no agents installed,
// or with a version that changed its layout, must produce an empty list rather
// than an error: this is a convenience, and a convenience that breaks the
// screen it is on is worse than one that is absent.

import { readFile, readdir, stat } from 'fs/promises'
import { join } from 'path'
import { homedir } from 'os'

/** How many directories to consider before sorting. Bounded so a home
 *  directory with years of history does not turn into a directory walk. */
const MAX_CANDIDATES = 400

/** How much of a transcript to read looking for a `cwd`. The field appears on
 *  every record, so the first line that has one wins — there is no need to
 *  read a session that may be hundreds of megabytes. */
const HEAD_BYTES = 65536

const AGENTS = ['claude', 'codex', 'cursor', 'opencode']

export function agentNames() { return [...AGENTS] }

/**
 * The working directory recorded in the head of a JSONL transcript, or null.
 *
 * Scans only as far as the first parseable line with a `cwd`, which is where
 * Claude Code and Codex both put it. A malformed line is skipped rather than
 * ending the scan: a transcript can be truncated mid-write while an agent is
 * running, and the record wanted is almost always before the break.
 */
export function cwdFromTranscriptHead(text) {
  if (typeof text !== 'string' || !text) return null
  for (const line of text.split('\n')) {
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

/**
 * The path a Claude Code project slug *probably* names.
 *
 * Lossy in both directions — a directory whose own name contains a dash becomes
 * indistinguishable from a separator — so the result is only ever offered as a
 * fallback with `inferred: true` on it. A wrong guess shown as certain is worse
 * than no guess.
 */
export function pathFromSlug(slug) {
  if (typeof slug !== 'string' || !slug.startsWith('-')) return null
  return '/' + slug.slice(1).replace(/-/g, '/')
}

/** Every `*.jsonl` under `dir`, recursively, with its mtime. Depth-limited and
 *  capped: this walks a directory we do not own. */
async function jsonlFiles(dir, depth = 0, found = []) {
  if (depth > 4 || found.length >= MAX_CANDIDATES) return found
  let entries
  try {
    entries = await readdir(dir, { withFileTypes: true })
  } catch {
    return found
  }
  for (const entry of entries) {
    if (found.length >= MAX_CANDIDATES) break
    const path = join(dir, entry.name)
    if (entry.isDirectory()) {
      await jsonlFiles(path, depth + 1, found)
    } else if (entry.name.endsWith('.jsonl')) {
      try {
        const info = await stat(path)
        found.push({ path, mtimeMs: info.mtimeMs })
      } catch {
        continue
      }
    }
  }
  return found
}

/** The head of a file, as text. */
async function head(path) {
  try {
    const buffer = await readFile(path)
    return buffer.subarray(0, HEAD_BYTES).toString('utf8')
  } catch {
    return ''
  }
}

/**
 * The directories the agents on this host have recently worked in.
 *
 * Returns `{ directories: [...] }`, newest first, each `{ path, at, agent,
 * inferred }`. `at` is milliseconds since the epoch, taken from the newest
 * transcript for that directory — which is when the agent was last active
 * there, not when the file was written.
 */
export async function recentDirectories(options = {}) {
  const home = options.home || homedir()
  const since = options.since || 0
  const byPath = new Map()

  const consider = (path, at, agent, inferred) => {
    if (!path || !path.startsWith('/') || at < since) return
    const existing = byPath.get(path)
    // Newest wins, and a real path beats an inferred one for the same
    // directory — otherwise a slug fallback could overwrite the answer.
    if (existing && existing.at >= at && !(existing.inferred && !inferred)) return
    byPath.set(path, { path, at, agent, inferred: Boolean(inferred) })
  }

  // Claude Code: one directory per project, one file per session.
  const claudeRoot = join(home, '.claude', 'projects')
  let projects = []
  try {
    projects = await readdir(claudeRoot, { withFileTypes: true })
  } catch {
    projects = []
  }
  for (const project of projects) {
    if (!project.isDirectory()) continue
    const dir = join(claudeRoot, project.name)
    const files = await jsonlFiles(dir)
    for (const file of files) {
      const cwd = cwdFromTranscriptHead(await head(file.path))
      consider(cwd || pathFromSlug(project.name), file.mtimeMs, 'claude', !cwd)
    }
  }

  // Codex and OpenCode keep their own trees. The layout differs from Claude
  // Code's but the records carry a `cwd` the same way, so the same reader
  // applies; a tree that is not there simply contributes nothing.
  for (const [agent, root] of [
    ['codex', join(home, '.codex', 'sessions')],
    ['opencode', join(home, '.local', 'share', 'opencode', 'project')],
    // Cursor's CLI keeps sessions alongside its editor state. It is the least
    // documented of the four and the most likely to move, which is why a
    // failure here is silent like the rest.
    ['cursor', join(home, '.cursor', 'cli', 'sessions')],
  ]) {
    for (const file of await jsonlFiles(root)) {
      const cwd = cwdFromTranscriptHead(await head(file.path))
      consider(cwd, file.mtimeMs, agent, false)
    }
  }

  const directories = [...byPath.values()].sort((a, b) => b.at - a.at)
  return { directories: directories.slice(0, options.limit || 20) }
}