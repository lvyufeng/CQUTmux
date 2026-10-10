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
// sixth git command with its own quoting.

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
