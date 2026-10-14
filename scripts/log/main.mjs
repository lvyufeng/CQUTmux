// The History tab's commit annotations, checked against a real repository.
//
// The row says what a commit changed, and every way of getting that wrong is
// quiet: a stat line read off the wrong commit, a merge reported as "0 files",
// a deleted commit that also claims "+0". So the fixture is a real repository
// driven through real git rather than a hand-typed copy of git's output —
// `--shortstat`'s wording is git's to change, and a fixture copied from a
// version of it proves only that the parser agrees with the copy.

import { execFileSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, writeFileSync, chmodSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { gitLog, parseLog, parseShortStat, logArgs } from '../../host/cqutmux-hook/revision.mjs'

let failures = 0
let checks = 0
function check(condition, label) {
  checks += 1
  if (condition) { console.log(`PASS  ${label}`) }
  else { failures += 1; console.log(`FAIL  ${label}`) }
}

const root = mkdtempSync(join(tmpdir(), 'cqutmux-log-'))
process.on('exit', () => rmSync(root, { recursive: true, force: true }))

function git(args, cwd = root) {
  return execFileSync('git', args, { cwd, stdio: ['ignore', 'pipe', 'pipe'] }).toString()
}

// A repository with one of each shape the parser has to tell apart.
git(['init', '-q', '.'])
git(['config', 'user.email', 'check@example.com'])
git(['config', 'user.name', 'check'])

writeFileSync(join(root, 'keep.txt'), 'one\ntwo\nthree\n')
writeFileSync(join(root, 'gone.txt'), 'soon removed\n')
git(['add', '.'])
git(['commit', '-qm', 'initial'])                       // 2 files, 4 insertions

writeFileSync(join(root, 'keep.txt'), 'one\nTWO\nthree\nfour\nfive\n')
git(['commit', '-qam', 'rewrite'])                      // 1 file, 3 insertions, 1 deletion

git(['rm', '-q', 'gone.txt'])
git(['commit', '-qm', 'delete a file'])                 // 1 file, 0 insertions, 1 deletion

chmodSync(join(root, 'keep.txt'), 0o755)
git(['commit', '-qam', '  only the mode changes'])      // 1 file, 0 insertions, 0 deletions

git(['checkout', '-qb', 'side'])
writeFileSync(join(root, 'keep.txt'), 'one\nTWO\nthree\nfour\nfive\nfrom side\n')
git(['commit', '-qam', 'side work'])
git(['checkout', '-q', '-'])
git(['merge', '-q', '--no-ff', '-m', 'merge side', 'side'])   // no diffstat at all

const bySubject = new Map()
const parsed = await gitLog(root)
for (const commit of parsed.commits) bySubject.set(commit.subject, commit)

console.log('— what git says, read back through the gateway —')
check(parsed.isRepo === true, 'the fixture is read as a repository')
check(parsed.commits.length === 6, `all six commits are listed (got ${parsed.commits.length})`)
check(bySubject.size === 6, 'and each has its own subject')

const initial = bySubject.get('initial')
check(initial?.files === 2, `the initial commit changed 2 files (got ${initial?.files})`)
check(initial?.insertions === 4 && initial?.deletions === 0,
      `and added 4 lines with none removed (got +${initial?.insertions} -${initial?.deletions})`)

const rewrite = bySubject.get('rewrite')
check(rewrite?.files === 1 && rewrite?.insertions === 3 && rewrite?.deletions === 1,
      `a rewrite reports both counts (got ${rewrite?.files}/${rewrite?.insertions}/${rewrite?.deletions})`)

// The one that must not become a zero: a merge has no diffstat, and `0 files`
// on every merge in the list is a claim git never made.
const merge = bySubject.get('merge side')
check(merge !== undefined, 'the merge is listed')
check(merge?.files === undefined && merge?.insertions === undefined && merge?.deletions === undefined,
      `a merge carries no counts at all (got ${JSON.stringify(merge && [merge.files, merge.insertions, merge.deletions])})`)

// A mode-only change *does* get a stat line, spelled with explicit zeros.
const mode = bySubject.get('  only the mode changes')
check(mode?.files === 1 && mode?.insertions === 0 && mode?.deletions === 0,
      `a mode-only change is one file with nothing added or removed (got ${JSON.stringify(mode && [mode.files, mode.insertions, mode.deletions])})`)

// The trap this parser is built around: git prints a stat line *starting with a
// space*, and a subject may start with one too. Matching "starts with a space"
// would attach the stat to the previous commit — or hide the subject — so the
// test is the `\x1f` separator, and this is the case that proves it.
const modeIndex = parsed.commits.findIndex(c => c.subject === '  only the mode changes')
check(modeIndex >= 0 && parsed.commits[modeIndex].files === 1,
      'a subject beginning with a space keeps its own stat line')
// And the counts below it belong to that commit, not to the mode change: a
// parser matching "line starts with a space" would have moved them.
const side = bySubject.get('side work')
check(side?.files === 1 && side?.insertions === 1 && side?.deletions === 0,
      `the next commit keeps its own counts (got ${side?.files}/${side?.insertions}/${side?.deletions})`)

console.log('\n— the two failures that are not "no commits" —')
const empty = join(root, '..', 'cqutmux-log-empty')
mkdirSync(empty, { recursive: true })
try {
  git(['init', '-q', '.'], empty)
  const noCommits = await gitLog(empty)
  check(noCommits.isRepo === true && noCommits.commits.length === 0,
        'a repository with no commits is a repository, not a missing one')
} finally {
  rmSync(empty, { recursive: true, force: true })
}

const plain = join(root, '..', 'cqutmux-log-plain')
mkdirSync(plain, { recursive: true })
try {
  const notRepo = await gitLog(plain)
  check(notRepo.isRepo === false && notRepo.commits.length === 0,
        'a directory that is not a repository still says so')
} finally {
  rmSync(plain, { recursive: true, force: true })
}

console.log('\n— the shapes on their own —')
check(parseShortStat(' 2 files changed, 3 insertions(+), 1 deletion(-)')?.files === 2, 'a plural stat line parses')
check(parseShortStat(' 1 file changed, 1 insertion(+)')?.deletions === 0,
      'a stat line with no deletions clause has none, not a parse failure')
check(parseShortStat(' 1 file changed, 1 deletion(-)')?.insertions === 0,
      'and one with no insertions clause is the mirror')
check(parseShortStat(' 1 file changed, 0 insertions(+), 0 deletions(-)')?.insertions === 0,
      'explicit zeros parse as zeros')
check(parseShortStat('fatal: not a git repository') === null, 'a non-stat line parses to nothing')
check(parseShortStat('') === null, 'and so does an empty one')

check(logArgs(1).includes('--shortstat'), 'the log arguments ask for the diffstat')
check(logArgs(500).includes('-n200') && logArgs(0).includes('-n40'),
      'the limit is clamped, and zero falls back to the default')

// A merge's missing stat, on a stream typed out to look like git's — including
// the blank line git leaves between commits, which a parser that expects each
// stat to directly follow its commit would trip on.
const stream = [
  'aaaa\x1faaa\x1fAnn\x1f2026-01-01T00:00:00+00:00\x1fa merge\x1fHEAD -> main',
  'bbbb\x1fbbb\x1fAnn\x1f2026-01-01T00:00:00+00:00\x1fa change\x1f',
  ' 2 files changed, 3 insertions(+), 1 deletion(-)',
  '',
  'cccc\x1fccc\x1fAnn\x1f2026-01-01T00:00:00+00:00\x1fanother\x1f',
  ' 1 file changed, 1 deletion(-)',
].join('\n')
const typed = parseLog(stream)
check(typed.length === 3, `three commits survive the blank line (got ${typed.length})`)
check(typed[0].files === undefined, 'the merge keeps no counts')
check(typed[1].files === 2 && typed[2].insertions === 0 && typed[2].deletions === 1,
      'and each stat lands on the commit above it')

if (failures > 0) {
  console.log(`\nLOG_FAIL  (${failures} of ${checks} failed)`)
  process.exit(1)
}
console.log(`\nLOG_PASS  (${checks} checks)`)
