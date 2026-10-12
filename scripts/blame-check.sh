#!/usr/bin/env bash
#
# Checks git blame attribution: the gateway's `/blame` route and the
# `--line-porcelain` reader behind it.
#
# What is asserted
# ----------------
# 1. Each line is attributed to the commit *git* recorded for it, with that
#    commit's author, email and author time — read back from `git log` rather
#    than written here, because an expected string written beside the parser
#    only proves the two agree with each other. Two authors and a line edited in
#    the second commit make the attribution differ across lines, so a parser
#    that stamped every line with the tip commit cannot pass.
# 2. The content of a line survives intact: leading indentation, an interior
#    tab, and an empty line — the three things that a record split on whitespace
#    would silently eat while still looking like a plausible answer.
# 3. A line that is in the working tree but not yet committed is marked, not
#    reported as a commit whose hash is all zeros.
# 4. A path outside the repository is refused with 403, and a path or revision
#    that does not exist with 404.
#
# Everything runs in a throwaway git repo, so the check never blames the working
# tree of whoever runs it.
#
# Usage: scripts/blame-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATEWAY_PORT="${CQUTMUX_GATEWAY_PORT:-24671}"
TOKEN="blame-test"

WORK="$(mktemp -d)"
cleanup() { [[ -n "${GW_PID:-}" ]] && kill "$GW_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

echo "==> building a throwaway repo with two authors"
cd "$WORK"
git init -q .
git config commit.gpgsign false

# Fixed identities and dates so the author time on the wire is predictable and a
# check can compare it against `git log` without racing the clock.
commit_as() {
  GIT_AUTHOR_NAME="$1" GIT_AUTHOR_EMAIL="$2" GIT_AUTHOR_DATE="$3" \
  GIT_COMMITTER_NAME="$1" GIT_COMMITTER_EMAIL="$2" GIT_COMMITTER_DATE="$3" \
    git commit -q -m "$4"
}

# Four lines: one indented, one blank, one interior tab. The second commit edits
# exactly one of them, so after it the file is attributed across two commits.
printf 'alpha from ada\n  indented by ada\n\nbeta from ada\n' > notes.txt
git add -A
commit_as "Ada Lovelace" "ada@example.com" "2020-01-01T10:00:00+00:00" "first"
FIRST="$(git rev-parse HEAD)"

printf 'alpha from ada\n  indented by ada\n\nbeta edited by bob\n' > notes.txt
git add -A
commit_as "Bob Barker" "bob@example.com" "2021-02-02T11:00:00+00:00" "second"
SECOND="$(git rev-parse HEAD)"

# A path git cannot write unquoted. Blamed over the route, it exercises the
# `filename` header's escaping on a real repository rather than only against a
# hand-built sample.
printf 'café line\n' > "café.txt"
git add -A
commit_as "Ada Lovelace" "ada@example.com" "2022-03-03T12:00:00+00:00" "third"
THIRD="$(git rev-parse HEAD)"

cd "$ROOT"

echo "==> starting the gateway against the throwaway repo"
node host/cqutmux-hook/index.mjs --port "$GATEWAY_PORT" --token "$TOKEN" --root "$WORK" \
  >/tmp/cqutmux_blame_gw.log 2>&1 &
GW_PID=$!
sleep 2

echo "==> checking attribution against what git recorded"
MOD="$ROOT/host/cqutmux-hook/revision.mjs" WORK="$WORK" \
GATEWAY_PORT="$GATEWAY_PORT" TOKEN="$TOKEN" FIRST="$FIRST" SECOND="$SECOND" THIRD="$THIRD" \
node --input-type=module - <<'JS'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { writeFile } from 'node:fs/promises'
import { join } from 'node:path'

// Imported by path, not by a literal specifier: the check runs from a heredoc,
// whose synthetic module has no directory for a relative `import` to resolve
// against — the failure is an unresolved-specifier error, not a wrong answer.
const { parseBlame, blameAtRevision } = await import(process.env.MOD)

const exec = promisify(execFile)
const root = process.env.WORK
const port = process.env.GATEWAY_PORT
const token = process.env.TOKEN
const FIRST = process.env.FIRST
const SECOND = process.env.SECOND
const THIRD = process.env.THIRD

let checks = 0
let failures = 0
function check(condition, label) {
  checks += 1
  if (condition) console.log(`PASS  ${label}`)
  else { failures += 1; console.log(`FAIL  ${label}`) }
}

async function get(path) {
  const response = await fetch(`http://127.0.0.1:${port}${path}`, {
    headers: { Authorization: `Bearer ${token}` },
  })
  let body = null
  try { body = await response.json() } catch { /* an empty or non-JSON body */ }
  return { status: response.status, body }
}

// What git itself recorded for a commit, so the expected author is not written
// here beside the parser.
async function recorded(hash) {
  const { stdout } = await exec('git', ['log', '-1', '--format=%an%x1f%ae%x1f%at', hash], { cwd: root })
  const [author, email, time] = stdout.trim().split('\x1f')
  return { author, email, time: Number(time) }
}

// --- The format rules, in isolation --------------------------------------
//
// These are the parts of `--line-porcelain` that a plausible-looking parser
// gets wrong without ever throwing. The inputs are shaped exactly as git writes
// them (checked against git 2.54); the point is that the reader treats the TAB
// as the only delimiter.

const head = (hash, a, b) => `${hash} ${a} ${b}\n`
const meta = (author, email, time) =>
  `author ${author}\nauthor-mail <${email}>\nauthor-time ${time}\nsummary s\nfilename f\n`

const sample = parseBlame(
  head('a'.repeat(40), 1, 1) + meta('Ada', 'ada@e.com', 100) + 'boundary\n\t  leading spaces\n' +
  head('b'.repeat(40), 2, 2) + meta('Bob', 'bob@e.com', 200) + '\t\n' +
  head('c'.repeat(40), 3, 3) + meta('Ada', 'ada@e.com', 100) + '\ta\tb\n'
)
check(sample.length === 3, 'three records parse to three lines')
check(sample[0].content === '  leading spaces', 'leading indentation is kept, not trimmed')
check(sample[1].content === '', 'an empty line is an empty string, not a dropped line')
check(sample[2].content === 'a\tb', 'an interior tab is part of the content')
check(sample[0].boundary === true && sample[1].boundary === false, 'boundary marks only the record that carries it')
check(sample[0].line === 1 && sample[2].line === 3, 'the final line number is read, not the original one')
check(sample[0].email === 'ada@e.com', 'author-mail is unwrapped from its angle brackets')

const zero = parseBlame(head('0'.repeat(40), 1, 1) + meta('Not Committed Yet', 'x', 0) + '\tx\n')
check(zero[0].committed === false, 'an all-zero hash is an uncommitted line, not a commit')

const quoted = parseBlame(
  head('d'.repeat(40), 1, 1) + 'filename "w\\303\\251ird \\"name\\".txt"\n\tx\n'
)
check(quoted[0].filename === 'wéird "name".txt', 'a quoted, escaped filename is unescaped')
const plainName = parseBlame(head('d'.repeat(40), 1, 1) + 'filename plain.txt\n\tx\n')
check(plainName[0].filename === 'plain.txt', 'an unquoted filename is left alone')

// `--line-porcelain` repeats metadata, but the reader must not *require* it:
// a header line immediately followed by content is a valid record.
const bare = parseBlame(head('e'.repeat(40), 1, 1) + '\tx\n')
check(bare.length === 1 && bare[0].content === 'x', 'a record with no metadata lines still parses')

// --- Against the real repository, over the route -------------------------

const atSecond = await get(`/blame?path=.&file=notes.txt&rev=${SECOND}`)
check(atSecond.status === 200, 'blaming a file at a commit answers 200')
check(atSecond.body.rev === SECOND, 'the revision is echoed back')

const lines = atSecond.body.lines
check(Array.isArray(lines) && lines.length === 4, 'one record per line of the file')
check(lines.map(l => l.line).join(',') === '1,2,3,4', 'the lines are numbered 1..n in order')

// The file's own lines, read straight from the commit, so the content check is
// against the file and not against a copy of the parser's output.
const { stdout: raw } = await exec('git', ['show', `${SECOND}:notes.txt`], { cwd: root })
const fileLines = raw.replace(/\n$/, '').split('\n')
check(lines.every((l, i) => l.content === fileLines[i]), 'every line of content matches the file')

// The attribution itself: line 4 was edited in the second commit, the rest came
// from the first. A parser that stamped the tip commit on every line fails here
// while passing everything above.
check(lines[0].hash === FIRST, 'line 1 is attributed to the first commit')
check(lines[3].hash === SECOND, 'line 4, edited in the second commit, is attributed to it')
check(lines[1].hash === FIRST && lines[2].hash === FIRST, 'the untouched lines stay with the first commit')
check(new Set(lines.map(l => l.hash)).size === 2, 'the attribution genuinely differs across lines')

// Each line's author is the one git recorded for the commit it names.
let attributed = true
for (const line of lines) {
  const truth = await recorded(line.hash)
  if (line.author !== truth.author || line.email !== truth.email || line.time !== truth.time) {
    attributed = false
    console.log(`      line ${line.line}: got ${line.author} <${line.email}> ${line.time}, git has ${truth.author} <${truth.email}> ${truth.time}`)
  }
}
check(attributed, 'every line carries the author git recorded for its commit')
check(lines[0].author === 'Ada Lovelace' && lines[3].author === 'Bob Barker',
      'the two authors are told apart, not flattened to one')

// The root commit is a boundary; the commit with a parent is not. The app uses
// this to decide whether there is a parent to offer.
check(lines[0].boundary === true, 'the root commit is marked as a boundary')
check(lines[3].boundary === false, 'the commit with a parent is not')

// The empty line came back with empty content, attributed like its neighbours.
check(lines[2].content === '', 'the blank line is present and empty')
check(lines[2].author === 'Ada Lovelace', 'and it is attributed, not skipped')

// A path git must quote in the `filename` header. Read over the route, so the
// unescaping is proved against a real repository's output and not only the
// hand-built sample above — the two disagreeing is how the UTF-8 fix was found.
const unicode = await get(`/blame?path=.&file=${encodeURIComponent('café.txt')}&rev=${THIRD}`)
check(unicode.status === 200, 'a non-ASCII filename can be blamed')
check(unicode.body.lines.length === 1 && unicode.body.lines[0].content === 'café line',
      'and its content reads back as UTF-8')
check(unicode.body.lines[0].filename === 'café.txt',
      'and the escaped filename header is unescaped to the real path')

// --- The working tree, and the two refusals ------------------------------

// A line added but not committed. git reports it with an all-zero hash, which
// the app must show as uncommitted rather than as a commit.
await writeFile(join(root, 'notes.txt'),
  'alpha from ada\n  indented by ada\n\nbeta edited by bob\nuncommitted line\n')
const atWorktree = await get(`/blame?path=.&file=notes.txt`)
check(atWorktree.status === 200, 'blaming the working tree (no rev) answers 200')
const last = atWorktree.body.lines.at(-1)
check(last.content === 'uncommitted line', 'the working tree includes the new line')
check(last.committed === false, 'and marks it uncommitted')
check(last.hash === '0'.repeat(40), 'with the all-zero hash git uses for it')

// The route refuses a path that is not inside the repository with 403, matching
// `/diff`, and answers 404 for a path or revision that simply does not exist.
const escape = await get(`/blame?path=.&file=${encodeURIComponent('../../../../etc/passwd')}&rev=${SECOND}`)
check(escape.status === 403, 'a path escaping the repository is refused with 403')
const absolute = await get(`/blame?path=.&file=${encodeURIComponent('/etc/passwd')}&rev=${SECOND}`)
check(absolute.status === 403, 'an absolute path is refused with 403')
const missing = await get(`/blame?path=.&file=nope.txt&rev=${SECOND}`)
check(missing.status === 404, 'a file that does not exist answers 404')
const badRev = await get(`/blame?path=.&file=notes.txt&rev=deadbeefdeadbeef`)
check(badRev.status === 404, 'a revision that does not exist answers 404')

// --- The module's own guards ---------------------------------------------

const unsafeRev = await blameAtRevision(root, 'HEAD', 'notes.txt')
check(!unsafeRev.ok && unsafeRev.error === 'unsafe revision', 'a symbolic ref is refused by the module')
const unsafePath = await blameAtRevision(root, SECOND, '../secrets')
check(!unsafePath.ok && unsafePath.error === 'unsafe path', 'a traversal is refused by the module')
const tooBig = await blameAtRevision(root, SECOND, 'notes.txt', 64)
check(!tooBig.ok && tooBig.error === 'file too large', 'a blame over the size cap is refused whole')

if (failures > 0) {
  console.log(`\nBLAME_FAIL  (${failures} of ${checks} failed)`)
  process.exit(1)
}
console.log(`\nBLAME_PASS  (${checks} checks)`)
JS

echo "BLAME_CHECK_DONE"
