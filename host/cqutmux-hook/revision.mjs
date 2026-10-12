// Reading the repository at a past commit.
//
// The Changes tab shows the working tree; the History tab lists commits but
// cannot open one. Both halves of "browse a commit" are the same shape — ask
// git for a tree or a blob at a revision — and both fail quietly in ways that
// look like an empty repository rather than a bug:
//
//   - `git show <rev>:<path>` also accepts a *branch* name and a *tag*, so a
//     revision that does not exist returns "fatal: ... unknown revision", which
//     the caller reads as "no such file". Asking for the object type first, and
//     only then the content, is what tells the two apart.
//   - The listing must not include `.git`, and must not descend into a
//     submodule's contents (which git represents as a separate commit, not as
//     blobs) — a symlink or a gitlink shown as a file would look like a file
//     that reads back empty.
//   - A path handed in from the app is arbitrary text. `rev:path` is one
//     argument, and a path with a leading `:` or a `-` is an option or a rev
//     separator unless it is passed after `--` or rejected.
//
// Kept apart from the gateway so the parsing — which is where these rules live
// — can be checked without a repository, and so the gateway does not grow a
// sixth git command with its own quoting. Blame is the third question asked of
// the same repository and is here for the same reason: `--line-porcelain` is a
// wire format with rules of its own (see `parseBlame`), not a git invocation
// the gateway should be trusted to quote correctly inline.

import { execFile } from 'child_process'
import { promisify } from 'util'

const exec = promisify(execFile)

/**
 * A path that can go into `rev:path` unambiguously.
 *
 * Refused rather than cleaned: an absolute path, a `..` segment, a leading
 * `-` (which git reads as an option) or a leading `:` (which it reads as the
 * rev separator) are all inputs the caller should not be producing, and
 * stripping them would silently answer a question about a different path.
 */
export function isSafeRepoPath(path) {
  if (typeof path !== 'string' || path === '') return false
  if (path.startsWith('/') || path.startsWith('-') || path.startsWith(':')) return false
  if (path.includes('\0')) return false
  return !path.split('/').includes('..')
}

/**
 * A revision expression that can be handed to git as its own argument.
 *
 * Deliberately narrow: hex object ids, and ref names made of the characters
 * git itself allows. `HEAD~2`, `main@{yesterday}` and a shell substitution are
 * not accepted — the app passes a commit hash straight from `git log`, so
 * anything else is either a mistake or an attempt to make git read a second
 * argument out of one string.
 */
export function isSafeRevision(rev) {
  if (typeof rev !== 'string' || rev === '') return false
  return /^[0-9a-fA-F]{4,64}$/.test(rev)
}

/**
 * `git ls-tree` output as entries.
 *
 * The format is `<mode> <type> <object>\t<name>`; the name is everything after
 * the tab, so a name containing spaces survives. `.git` is dropped — it is not
 * part of the tree the user is browsing — and a submodule (`commit`) is marked
 * so the app can say so rather than open it as an empty file.
 */
export function parseTree(stdout) {
  const lines = String(stdout || '').split('\n').filter(Boolean)
  const entries = []
  for (const line of lines) {
    const tab = line.indexOf('\t')
    if (tab < 0) continue
    const [mode, type, object] = line.slice(0, tab).split(' ')
    const name = line.slice(tab + 1)
    if (!name || name === '.git') continue
    entries.push({
      name,
      // `tree` is a directory; `blob` a file; `commit` a submodule, which is a
      // directory to the reader but has no blobs of its own to list.
      dir: type === 'tree' || type === 'commit',
      submodule: type === 'commit',
      mode: mode || '',
      object: object || '',
    })
  }
  return entries.sort((a, b) =>
    a.dir === b.dir ? a.name.localeCompare(b.name) : a.dir ? -1 : 1)
}

/** The arguments for listing one directory of a revision's tree. */
export function treeArgs(rev, path) {
  const target = path ? `${rev}:${path}` : rev
  return ['ls-tree', target]
}

/**
 * The arguments for one file's content at a revision.
 *
 * `-p`/`--pretty` is not used: `git show rev:path` prints the blob itself with
 * no wrapper, which is what the viewer wants. The object type is checked by the
 * caller first, so this is only reached for a blob.
 */
export function blobArgs(rev, path) {
  return ['show', `${rev}:${path}`]
}

/** The arguments for the type of one path at a revision. */
export function typeArgs(rev, path) {
  return ['cat-file', '-t', `${rev}:${path}`]
}

/**
 * Reads a directory of a revision's tree.
 *
 * Fails closed on the two rules above rather than passing the strings to git:
 * a rejected path or revision is the caller's bug, and git would answer it with
 * a message about a revision the user never named.
 */
export async function listAtRevision(cwd, rev, path = '') {
  if (!isSafeRevision(rev)) return { ok: false, error: 'unsafe revision' }
  if (path && !isSafeRepoPath(path)) return { ok: false, error: 'unsafe path' }
  try {
    const { stdout } = await exec('git', treeArgs(rev, path), { cwd, maxBuffer: 8 * 1024 * 1024 })
    return { ok: true, path, entries: parseTree(stdout) }
  } catch (error) {
    return { ok: false, error: String(error.stderr || error.message || error).trim().slice(0, 300) }
  }
}

/**
 * Reads one file's content at a revision.
 *
 * The type is asked first so a directory or a submodule is refused with a
 * message that says which it is. `git show rev:dir` answers with the tree's
 * raw bytes, which would render as a wall of binary rather than as "that is a
 * directory".
 */
export async function readAtRevision(cwd, rev, path, limit = 512 * 1024) {
  if (!isSafeRevision(rev)) return { ok: false, error: 'unsafe revision' }
  if (!isSafeRepoPath(path)) return { ok: false, error: 'unsafe path' }
  try {
    const { stdout: type } = await exec('git', typeArgs(rev, path), { cwd })
    const kind = String(type).trim()
    if (kind !== 'blob') return { ok: false, error: `not a file (${kind})` }
    const { stdout } = await exec('git', blobArgs(rev, path), {
      cwd,
      maxBuffer: Math.max(limit * 2, 1024 * 1024),
    })
    if (Buffer.byteLength(stdout) > limit) return { ok: false, error: 'file too large' }
    return { ok: true, path, content: stdout }
  } catch (error) {
    return { ok: false, error: String(error.stderr || error.message || error).trim().slice(0, 300) }
  }
}

/**
 * Undoes git's C-style quoting of a `filename` header.
 *
 * `git blame` quotes and escapes the path when it contains anything outside
 * plain ASCII — a space is left alone, but a quote, a tab, a newline or a
 * non-ASCII byte makes the whole path a quoted string with octal escapes.
 * Returned as-is when it is not quoted: unquoting a path that was never quoted
 * would eat a backslash that is really in the name.
 *
 * The escapes handled are the ones `quote_c_style` writes: `\a\b\f\n\r\t\v\\`
 * `\"` and `\ooo` octal. Each `\ooo` is one *byte* of a UTF-8 sequence, not one
 * character — git quotes `é` as `\303\251`, two bytes — so the decoded bytes are
 * collected and decoded as UTF-8 at the end. Turning each escape straight into
 * a character would yield `Ã©`, a mojibake path that looks like a rename.
 */
function unquotePath(raw) {
  if (!raw.startsWith('"') || !raw.endsWith('"') || raw.length < 2) return raw
  const body = raw.slice(1, -1)
  const simple = { a: 7, b: 8, f: 12, n: 10, r: 13, t: 9, v: 11, '\\': 92, '"': 34 }
  const bytes = []
  const push = ch => { for (const byte of Buffer.from(ch, 'utf8')) bytes.push(byte) }
  for (let i = 0; i < body.length; i++) {
    if (body[i] !== '\\') { push(body[i]); continue }
    const next = body[++i]
    if (next in simple) { bytes.push(simple[next]); continue }
    if (next >= '0' && next <= '7') {
      let octal = next
      while (octal.length < 3 && body[i + 1] >= '0' && body[i + 1] <= '7') octal += body[++i]
      bytes.push(parseInt(octal, 8) & 0xff)
      continue
    }
    // A backslash before anything else is git's own escaping of a character it
    // did not need to escape; keep the character, not the backslash.
    push(next)
  }
  return Buffer.from(bytes).toString('utf8')
}

/** `author-mail <a@b>` → `a@b`; git writes the address wrapped in angle brackets. */
function stripAngleBrackets(value) {
  return value.startsWith('<') && value.endsWith('>') ? value.slice(1, -1) : value
}

/**
 * `git blame --line-porcelain` output as per-line attribution.
 *
 * `--line-porcelain` rather than `--porcelain` deliberately. The plain form
 * prints a commit's full metadata once and elides it for that commit's later
 * lines — which means a correct reader has to carry commit state forward across
 * records, and the one place that state can go stale is exactly where two
 * records of the same commit are adjacent. The line form repeats the metadata
 * before *every* line, so each record stands alone and there is no carried
 * state to get wrong; the cost is bytes on a loopback socket.
 *
 * A record is the metadata lines, then a line whose first byte is a TAB. That
 * tab is the only delimiter: the content after it is the line as it is in the
 * file and can begin with spaces, contain tabs, or be empty (an empty line in
 * the file is a lone TAB followed by nothing). Splitting a record on whitespace
 * would silently strip that leading indentation — a blame column that shifts
 * every indented line one tab to the left, which reads as a formatting choice
 * rather than as corruption.
 *
 * The header line is `<sha> <orig-line> <final-line> [<group-size>]`. The sha
 * can be all zeros: git uses it for a line that is in the working tree but not
 * yet committed, so those come back as `committed: false` rather than as a
 * commit whose hash happens to be zeros.
 *
 * `boundary` marks a commit at the edge of the blamed range — the root commit,
 * or one whose parents were not walked — so the app can say the history stops
 * here rather than offer a parent that does not exist.
 */
export function parseBlame(stdout) {
  const records = String(stdout || '').split('\n')
  const lines = []
  let current = null
  for (const record of records) {
    if (record.startsWith('\t')) {
      if (current) {
        current.content = record.slice(1)
        lines.push(current)
        current = null
      }
      continue
    }
    if (record === '') continue
    const header = /^([0-9a-fA-F]{40,64}) (\d+) (\d+)(?: (\d+))?$/.exec(record)
    if (header) {
      current = {
        hash: header[1].toLowerCase(),
        line: Number(header[3]),
        author: '',
        email: '',
        time: null,
        summary: '',
        filename: '',
        previous: null,
        boundary: false,
        committed: !/^0+$/.test(header[1]),
        content: '',
      }
      continue
    }
    if (!current) continue
    const space = record.indexOf(' ')
    const key = space < 0 ? record : record.slice(0, space)
    const value = space < 0 ? '' : record.slice(space + 1)
    if (key === 'author') current.author = value
    else if (key === 'author-mail') current.email = stripAngleBrackets(value)
    else if (key === 'author-time') current.time = Number(value)
    else if (key === 'summary') current.summary = value
    else if (key === 'filename') current.filename = unquotePath(value)
    else if (key === 'boundary') current.boundary = true
    else if (key === 'previous') {
      // `previous <sha> <filename>`; the filename is quoted the same way, and a
      // `previous` with no path means git knew no parent.
      const parts = value.split(' ')
      if (parts[0]) current.previous = parts[0].toLowerCase()
    }
  }
  return lines
}

/**
 * The arguments for attributing each line of one file.
 *
 * `--` before the path so a filename that looks like a flag or a revision is a
 * path. `-l` is not passed: a short hash is the app's business (`RevisionPath`)
 * and the full object id is what a later lookup needs.
 */
export function blameArgs(rev, path) {
  return rev
    ? ['blame', '--line-porcelain', rev, '--', path]
    : ['blame', '--line-porcelain', '--', path]
}

/**
 * Blames one file, returning a per-line attribution.
 *
 * `rev` is optional: omitted, git blames the working tree (and any line not yet
 * committed comes back with an all-zero hash, which `parseBlame` marks). Given,
 * it blames the file as it stood at that commit.
 *
 * The size cap is applied to git's own output rather than to the file: porcelain
 * is several times the file's size, and a file just under the cap would blow the
 * budget several times over once every line carries a full commit header. Over
 * the cap the whole response is refused, matching `/file` — a partial set of
 * lines would show as a file whose tail is attributed to nobody.
 */
export async function blameAtRevision(cwd, rev, path, limit = 512 * 1024) {
  if (rev && !isSafeRevision(rev)) return { ok: false, error: 'unsafe revision' }
  if (!isSafeRepoPath(path)) return { ok: false, error: 'unsafe path' }
  try {
    const { stdout } = await exec('git', blameArgs(rev, path), {
      cwd,
      maxBuffer: Math.max(limit * 2, 1024 * 1024),
    })
    if (Buffer.byteLength(stdout) > limit) return { ok: false, error: 'file too large' }
    return { ok: true, path, rev: rev || '', lines: parseBlame(stdout) }
  } catch (error) {
    return { ok: false, error: String(error.stderr || error.message || error).trim().slice(0, 300) }
  }
}
