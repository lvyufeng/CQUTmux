// Reading the shell's own command history.
//
// The point of this is narrow and worth stating, because the obvious
// alternative is worse: a phone keyboard makes retyping a long command
// miserable, and the command someone wants is almost always one they ran
// recently on the host. Reading `~/.zsh_history` gives exactly that, with none
// of the guesswork that scraping a terminal pane would need — and the history
// file is already the user's, already on the machine, and already written for
// this purpose.
//
// Two formats have to be handled, and they are interleaved in the same file in
// practice because a shell can be upgraded under a history file:
//
//   extended   `: 1700000000:0;git rebase -i HEAD~3`
//   plain      `git rebase -i HEAD~3`
//
// Extended records carry the timestamp and a duration, then a `;` and the
// command — and the command itself may contain `;`, so the split is on the
// *first* one. A multi-line command is stored across several physical lines
// with the continuation escaped as `\\` at the end, which has to be joined back
// before the record is usable.
//
// Nothing here is authoritative: a history file may be truncated, may be
// missing, may belong to a shell that is not the one running. Every failure
// degrades to an empty list.

import { readFile, stat } from 'fs/promises'
import { join } from 'path'
import { homedir } from 'os'

/** How much of each history file to read. The tail is where the recent
 *  commands are, but the *file* has to be read whole to know where its tail
 *  is, so this bounds it: a history file can be tens of megabytes. */
const MAX_BYTES = 512 * 1024

/** Commands are shown newest first and bounded: this is a picker, not an
 *  archive, and 500 entries is more than anyone scrolls. */
const MAX_COMMANDS = 200

/**
 * Splits a history file into commands, newest last.
 *
 * Exported for the check script: the escaping rules are the part that is easy
 * to get subtly wrong and impossible to notice by looking at a menu.
 */
export function parseHistory(text) {
  if (typeof text !== 'string' || !text) return []
  const commands = []
  let pending = ''

  for (const rawLine of text.split('\n')) {
    if (!rawLine) continue

    // A trailing backslash is a line continuation: the record is not finished.
    // Joining with a newline rather than a space matters — a `for` loop or a
    // quoted string spanning lines would otherwise be presented as one line
    // and typed back as something that does not mean the same thing.
    if (rawLine.endsWith('\\')) {
      pending += rawLine.slice(0, -1) + '\n'
      continue
    }
    const line = pending + rawLine
    pending = ''

    // Extended format. `: <epoch>:<duration>;<command>` — the split is on the
    // first `;` because the command may contain several.
    let command = line
    let at = null
    if (line.startsWith(': ')) {
      const separator = line.indexOf(';')
      if (separator !== -1) {
        const stamp = line.slice(2, separator)
        const epoch = Number(stamp.split(':')[0])
        if (Number.isFinite(epoch) && epoch > 0) at = epoch * 1000
        command = line.slice(separator + 1)
      }
    }
    command = command.trim()
    if (command) commands.push({ command, at })
  }

  // A history file is stored oldest-first; the caller wants newest-first.
  return commands.reverse()
}

/** The history files to read, in the order a shell would prefer them. */
function historyFiles(home, shell) {
  const zsh = ['zsh', 'zsh-history', ''].includes(shell || '')
  const files = []
  if (zsh || !shell) {
    if (process.env.HISTFILE) files.push(process.env.HISTFILE)
    if (process.env.ZDOTDIR) files.push(join(process.env.ZDOTDIR, '.zsh_history'))
    files.push(join(home, '.zsh_history'))
  }
  if (!zsh || !shell) {
    if (process.env.HISTFILE) files.push(process.env.HISTFILE)
    files.push(join(home, '.bash_history'))
  }
  return [...new Set(files.filter(Boolean))]
}

/** The tail of a file, as text, without splitting a UTF-8 sequence. */
async function readTail(path) {
  try {
    const info = await stat(path)
    if (!info.isFile() || info.size === 0) return ''
    const handle = await readFile(path)
    const slice = info.size > MAX_BYTES ? handle.subarray(info.size - MAX_BYTES) : handle
    // Decoding from the middle of a multi-byte character yields a replacement
    // character on the first line, which is harmless — the first line is
    // discarded anyway when the cut was not at a record boundary.
    return slice.toString('utf8')
  } catch {
    return ''
  }
}

/**
 * The commands run recently on this host, newest first.
 *
 * `{ commands: [{ command, at, shell }] }`, deduplicated by command text:
 * running `ls` forty times in a session should not fill the list. The newest
 * occurrence wins, since that is when it was last useful.
 */
export async function commandHistory(options = {}) {
  const home = options.home || homedir()
  const limit = options.limit || MAX_COMMANDS
  const seen = new Map()

  for (const path of historyFiles(home, options.shell)) {
    let text = await readTail(path)
    if (!text) continue
    // A cut at MAX_BYTES lands mid-line, so drop the first (partial) line.
    // Only when the file was actually truncated — dropping it otherwise would
    // silently lose the oldest command in a short file.
    try {
      const info = await stat(path)
      if (info.size > MAX_BYTES) text = text.slice(text.indexOf('\n') + 1)
    } catch {
      continue
    }
    const shell = path.includes('zsh') || process.env.ZDOTDIR ? 'zsh' : 'bash'
    for (const record of parseHistory(text)) {
      const existing = seen.get(record.command)
      if (existing && (existing.at || 0) >= (record.at || 0)) continue
      seen.set(record.command, { ...record, shell })
    }
  }

  // Sort by time where there is one. A plain-format record has none, and the
  // honest thing is to leave it where the file put it rather than to treat the
  // absence as "epoch 0" and sink it to the bottom: the file's own order *is*
  // chronological, so a record without a timestamp still has a position that
  // means something. `sort` is stable, so returning 0 keeps insertion order.
  const commands = [...seen.values()].sort((a, b) => {
    if (a.at && b.at) return b.at - a.at
    return 0
  })
  return { commands: commands.slice(0, limit) }
}