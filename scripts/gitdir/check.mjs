// Whether browsing a past commit reads the right tree.
//
// Every rule here fails as a *plausible* answer rather than as an error. A
// rejected path that is quietly cleaned answers about a different file; a
// revision that git reads as a second argument answers about a different
// commit; a directory read as a file renders as binary noise. So the checks run
// against a real repository where those answers are reachable, and assert on
// what came back, not on whether the call threw.

import { mkdtemp, mkdir, writeFile, rm } from 'fs/promises'
import { tmpdir } from 'os'
import { join } from 'path'
import { execFile } from 'child_process'
import { promisify } from 'util'
import {
  isSafeRepoPath, isSafeRevision, parseTree, listAtRevision, readAtRevision,
} from '../../host/cqutmux-hook/revision.mjs'

const exec = promisify(execFile)

let checks = 0
let failures = 0

function check(condition, label) {
  checks += 1
  if (condition) {
    console.log(`PASS  ${label}`)
  } else {
    failures += 1
    console.log(`FAIL  ${label}`)
  }
}

// MARK: - Paths git is handed

// Paths that are exactly what they look like.
for (const path of ['README.md', 'src/main.swift', 'a b/c d.txt', 'deep/er/nested.mjs']) {
  check(isSafeRepoPath(path), `a plain repo path is accepted: ${path}`)
}

// The refusals. Each of these would otherwise reach git as something other than
// a path inside the tree.
check(!isSafeRepoPath(''), 'an empty path is refused')
check(!isSafeRepoPath('/etc/passwd'), 'an absolute path is refused')
check(!isSafeRepoPath('src/../../etc/passwd'), 'a path escaping upward is refused')
check(!isSafeRepoPath('-p'), 'a leading dash is refused rather than read as an option')
check(!isSafeRepoPath(':/etc/passwd'), 'a leading colon is refused rather than read as a revision')
check(!isSafeRepoPath('a/b/../c'), 'an interior parent segment is refused')
check(!isSafeRepoPath(null), 'a missing path is refused')
// A `..` inside a *filename* is not a traversal, and refusing it would hide a
// real file.
check(isSafeRepoPath('src/..hiddensuffix'), 'a name merely containing dots is accepted')

// MARK: - Revisions

check(isSafeRevision('a1b2c3d'), 'a short hex id is accepted')
check(isSafeRevision('0'.repeat(40)), 'a full 40-character id is accepted')
check(!isSafeRevision('HEAD'), 'a symbolic ref is refused')
check(!isSafeRevision('main~2'), 'a relative ref is refused')
check(!isSafeRevision('a1b2c3d --output=/tmp/x'), 'a revision with an argument appended is refused')
check(!isSafeRevision('$(whoami)'), 'a substitution is refused')
check(!isSafeRevision('abc'), 'a too-short fragment is refused')
check(!isSafeRevision(''), 'an empty revision is refused')

// MARK: - Parsing `git ls-tree`

const tree = [
  '100644 blob aaa\tREADME.md',
  '040000 tree bbb\tsrc',
  '100644 blob ccc\tname with spaces.txt',
  '160000 commit ddd\tsub',
  '100644 blob eee\t.git',
].join('\n')

const parsed = parseTree(tree)
check(parsed.length === 4, 'dot-git is dropped from a listing')
check(!parsed.some(e => e.name === '.git'), 'and nothing named dot-git comes back')
check(parsed[0].name === 'src' && parsed[0].dir && !parsed[0].submodule,
      'a tree is a directory and not a submodule')
const spaced = parsed.find(e => e.name.startsWith('name with'))
check(spaced && spaced.name === 'name with spaces.txt' && !spaced.dir,
      'the name is everything after the tab, spaces included')
check(parsed.some(e => e.name === 'sub' && e.submodule),
      'a submodule is marked, not silently shown as a file')
const dirs = parsed.filter(e => e.dir).map(e => e.name)
check(dirs[0] === 'src' && dirs.length === 2, 'directories sort ahead of files')
check(parseTree('').length === 0, 'an empty listing parses to nothing')

// MARK: - Against a real repository

const root = await mkdtemp(join(tmpdir(), 'cqutmux-gitdir-'))
const git = (...a) => exec('git', a, { cwd: root })

try {
  await git('init', '-q')
  await git('config', 'user.email', 'c@example.com')
  await git('config', 'user.name', 'Check')
  await git('config', 'commit.gpgsign', 'false')

  await writeFile(join(root, 'README.md'), 'first\n')
  await mkdir(join(root, 'src'), { recursive: true })
  await writeFile(join(root, 'src', 'main.swift'), 'print("one")\n')
  await git('add', '-A')
  await git('commit', '-q', '-m', 'first')
  const first = (await git('rev-parse', 'HEAD')).stdout.trim()

  // A second commit changes an existing file, deletes one and adds another, so
  // every "at this revision" question has a different answer from the working
  // tree and from the first commit.
  await writeFile(join(root, 'README.md'), 'second\n')
  await writeFile(join(root, 'src', 'main.swift'), 'print("two")\n')
  await writeFile(join(root, 'extra.txt'), 'new\n')
  await git('add', '-A')
  await git('commit', '-q', '-m', 'second')
  const second = (await git('rev-parse', 'HEAD')).stdout.trim()

  // The listing at the first commit does not contain the later file — this is
  // the whole point of browsing a commit, and a listing that read the working
  // tree would pass every other check here.
  const atFirst = await listAtRevision(root, first)
  check(atFirst.ok, 'the first commit lists')
  check(!atFirst.entries.some(e => e.name === 'extra.txt'),
        'a file added later is absent from the earlier commit')
  check(atFirst.entries.some(e => e.name === 'README.md' && !e.dir), 'a file is listed as a file')
  check(atFirst.entries.some(e => e.name === 'src' && e.dir), 'a directory is listed as a directory')

  const atSecond = await listAtRevision(root, second)
  check(atSecond.entries.some(e => e.name === 'extra.txt'),
        'the later commit does list the file it added')

  // Descending: the same subdirectory holds different content at the two
  // commits, and the listing has to be rooted at the commit, not at the disk.
  const sub = await listAtRevision(root, first, 'src')
  check(sub.ok && sub.entries.length === 1 && sub.entries[0].name === 'main.swift',
        'a subdirectory at a revision lists its own contents')

  // Reading a file at the first commit gives the *first* content — the check
  // that separates "handed the revision to git" from "read the file on disk".
  const read = await readAtRevision(root, first, 'README.md')
  check(read.ok && read.content === 'first\n', 'a file reads as it was at that revision')
  const readSecond = await readAtRevision(root, second, 'README.md')
  check(readSecond.ok && readSecond.content === 'second\n',
        'and the same path reads differently at the other revision')

  // A file that did not exist yet is a clean refusal, not an empty string that
  // the viewer would draw as an empty file.
  const absent = await readAtRevision(root, first, 'extra.txt')
  check(!absent.ok && /did not exist|exists on disk|unknown revision|path/i.test(absent.error),
        'a file absent from that revision is refused')

  // A directory read as a file would render as a wall of binary; the type is
  // asked first so it says which it is.
  const asFile = await readAtRevision(root, first, 'src')
  check(!asFile.ok && /tree/.test(asFile.error), 'reading a directory as a file names it a tree')

  // An unknown revision is an error, not an empty listing — the two look the
  // same on screen otherwise.
  const bogus = await listAtRevision(root, 'deadbeefdeadbeef')
  check(!bogus.ok, 'an unknown revision fails rather than listing nothing')

  // A revision that is really a path is refused before git sees it.
  const traversal = await readAtRevision(root, first, '../secrets')
  check(!traversal.ok && traversal.error === 'unsafe path', 'a traversal is refused by the module')
  const flag = await listAtRevision(root, first, '-p')
  check(!flag.ok && flag.error === 'unsafe path', 'a flag-shaped path is refused by the module')
  const symbolic = await listAtRevision(root, 'HEAD')
  check(!symbolic.ok && symbolic.error === 'unsafe revision',
        'a symbolic ref is refused by the module')
} finally {
  await rm(root, { recursive: true, force: true })
}

if (failures > 0) {
  console.log(`\nGITDIR_FAIL  (${failures} of ${checks} failed)`)
  process.exit(1)
}
console.log(`\nGITDIR_PASS  (${checks} checks)`)
