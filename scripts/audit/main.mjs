// The parity audit's own numbers, checked against the things they describe.
//
// docs/parity-audit.json exists so a reader who cannot re-run the work can
// trust it. It has been wrong in ways nothing noticed — a status table that
// disagreed with the counters it was said to agree with, a `verification` field
// that described the opposite of its own `evidence`, and check counts quoted
// from runs long past (one cited "sidebyside-check.sh (36 checks)" after the
// check had reached 52). Every one of those is a *number* the file states about
// something this repository can re-measure, which is exactly the kind of claim
// a script should hold to account rather than a careful reader.
//
// What it cannot check is judgement — whether a `closed` is deserved. It checks
// the arithmetic, the vocabulary, the references, and the counts.

import { readFileSync, existsSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { dirname, join } from 'node:path'

const ROOT = join(dirname(import.meta.dirname), '..')
const JSON_PATH = join(ROOT, 'docs', 'parity-audit.json')
const MD_PATH = join(ROOT, 'docs', 'parity-audit.md')
const STATUSES = ['closed', 'partial', 'missing', 'deliberate-divergence']

let failures = 0
let checks = 0
function check(condition, label) {
  checks += 1
  if (condition) { console.log(`PASS  ${label}`) }
  else { failures += 1; console.log(`FAIL  ${label}`) }
}

// `--observed <file>`: one `<script> <count>` line per check this run executed.
// Absent, the counts are reported as unverified rather than assumed right.
const observedArg = process.argv.indexOf('--observed')
const observedPath = observedArg >= 0 ? process.argv[observedArg + 1] : null
const observed = new Map()
if (observedPath && existsSync(observedPath)) {
  for (const line of readFileSync(observedPath, 'utf8').split('\n')) {
    const [name, count] = line.trim().split(/\s+/)
    if (name && count) observed.set(name, Number(count))
  }
}

// MARK: - The file parses, here and as committed

let raw = null
let doc = null
try {
  raw = readFileSync(JSON_PATH, 'utf8')
  doc = JSON.parse(raw)
} catch (error) {
  check(false, `docs/parity-audit.json parses (${String(error.message).slice(0, 120)})`)
}

if (!doc) {
  console.log(failures > 0 ? `\nAUDIT_FAIL  (${failures} of ${checks} failed)` : '')
  process.exit(1)
}
check(true, 'docs/parity-audit.json parses')

// A working tree can be repaired after the commit that broke it, so the blob a
// reader actually receives is the one that has to parse. The file was committed
// broken once, by an unescaped quote inside a long string field.
try {
  const committed = execFileSync('git', ['show', 'HEAD:docs/parity-audit.json'],
    { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })
  let committedDoc = null
  try { committedDoc = JSON.parse(committed) } catch { /* reported below */ }
  check(committedDoc !== null, 'and the committed blob parses too, not just the working tree')
} catch {
  // No git, or the file is not tracked yet: nothing to compare, and saying so
  // is better than a silent pass that reads like a verification.
  console.log('SKIP  the committed blob (git or HEAD unavailable)')
}

const confirmed = Array.isArray(doc.confirmed) ? doc.confirmed : []
const refuted = Array.isArray(doc.refuted) ? doc.refuted : []
const md = existsSync(MD_PATH) ? readFileSync(MD_PATH, 'utf8') : ''

// MARK: - Every entry says what it is

check(confirmed.length > 0, `the audit holds confirmed entries (${confirmed.length})`)
check(confirmed.every(e => typeof e.claim === 'string' && e.claim.trim()),
      'every confirmed entry carries a claim')
check(confirmed.every(e => typeof e.evidence === 'string' && e.evidence.trim()),
      'and evidence')
check(confirmed.every(e => typeof e.verification === 'string' && e.verification.trim()),
      'and a verification')
check(confirmed.every(e => typeof e.page === 'string' && e.page.trim()),
      'and names the doc page it came from')

const unknown = [...new Set(confirmed.map(e => e.status))].filter(s => !STATUSES.includes(s))
check(unknown.length === 0, `no entry carries a status outside the vocabulary (${unknown.join(', ') || 'none'})`)

// Two entries with the same wording are a paste, and the second one's evidence
// is then about the first one's claim.
const claimTexts = confirmed.map(e => e.claim.trim())
check(new Set(claimTexts).size === claimTexts.length,
      `no two entries share a claim (${claimTexts.length - new Set(claimTexts).size} duplicates)`)

// MARK: - The counters are derived, not typed

const tally = {}
for (const status of STATUSES) tally[status] = 0
for (const entry of confirmed) {
  if (tally[entry.status] === undefined) tally[entry.status] = 0
  tally[entry.status] += 1
}
const counters = doc.counters || {}
for (const status of STATUSES) {
  check(counters[status] === (tally[status] || 0),
        `counters.${status} is the tally of the entries (${counters[status]} vs ${tally[status] || 0})`)
}

// The refuted list is summarised by a number as well, and a number that is not
// re-derived is the shape this whole file keeps failing in.
check(refuted.length === doc.refutedCount,
      `refutedCount matches the refuted list (${doc.refutedCount} vs ${refuted.length})`)

// MARK: - The prose table agrees with the counters

// The table in parity-audit.md was hand-maintained and read 73 while the JSON
// it was next to read 78, for five closures. Nothing re-derived it. It is still
// hand-written — that is fine — but now it is checked.
const tableRows = new Map()
for (const line of md.split('\n')) {
  const m = /^\|\s*(closed|partial|deliberate-divergence|missing)\s*\|\s*(\d+)\s*\|/.exec(line)
  if (m) tableRows.set(m[1], Number(m[2]))
}
check(tableRows.size > 0, 'the status table is present in parity-audit.md')
for (const [status, count] of tableRows) {
  check(counters[status] === count,
        `the md table's ${status} row agrees with the counters (${count} vs ${counters[status]})`)
}
for (const status of STATUSES) {
  check(tableRows.has(status), `and has a row for ${status}`)
}

// MARK: - Every script the audit names exists

// Both the JSON and the prose cite check scripts, and a citation is a promise
// that the work is still pinned. A renamed or deleted script leaves the promise
// standing and the check gone.
const SCRIPT = /([a-z0-9][a-z0-9./-]*-check\.sh)/g
function eachString(value, sink) {
  if (typeof value === 'string') sink(value)
  else if (Array.isArray(value)) value.forEach(v => eachString(v, sink))
  else if (value && typeof value === 'object') Object.values(value).forEach(v => eachString(v, sink))
}

const scripts = new Set()
eachString(doc, text => {
  for (const m of text.matchAll(SCRIPT)) scripts.add(m[1].split('/').pop())
})
for (const m of md.matchAll(SCRIPT)) scripts.add(m[1].split('/').pop())

const broken = [...scripts].filter(name => !existsSync(join(ROOT, 'scripts', name)))
check(broken.length === 0,
      `every cited check script exists (${broken.join(', ') || 'all ' + scripts.size} present)`)

// MARK: - The counts the audit quotes are the counts the checks print

// A cited count is only ever the first parenthetical right after the script's
// name: the file also quotes older numbers on purpose ("it read 79 when this
// was written"), and those are history, not claims.
const CLAIM = /^`?\s*\((\d+)(?:\s+checks?)?\)/
const claimed = new Map()
function collectClaims(text) {
  for (const m of String(text).matchAll(SCRIPT)) {
    const name = m[1].split('/').pop()
    const after = m.index + m[0].length
    const c = CLAIM.exec(String(text).slice(after, after + 40))
    if (!c) continue
    if (!claimed.has(name)) claimed.set(name, new Set())
    claimed.get(name).add(Number(c[1]))
  }
}
eachString(doc, collectClaims)
collectClaims(md)

const contradictory = [...claimed].filter(([, counts]) => counts.size > 1)
check(contradictory.length === 0,
      `no script is cited at two different counts (${contradictory.map(([n, c]) => n + ': ' + [...c].join('/')).join(', ') || 'none'})`)

let compared = 0
const unobserved = []
const wrong = []
for (const [name, counts] of claimed) {
  const [cited] = [...counts]
  const actual = observed.get(name)
  if (actual === undefined) { unobserved.push(name); continue }
  compared += 1
  if (actual !== cited) wrong.push(`${name}: cites ${cited}, printed ${actual}`)
}
if (!observedPath) {
  // Reported rather than assumed: a run that never measured these scripts cannot
  // say their numbers are right, and a silent pass here would read like one.
  console.log(`SKIP  the ${claimed.size} cited counts — pass --observed <file> from a run to compare them`)
} else {
  console.log(`      ${compared} of ${claimed.size} cited counts compared against this run` +
    (unobserved.length ? `; not run here: ${unobserved.join(', ')}` : ''))
  check(wrong.length === 0, `every cited count is the count the check prints (${wrong.join('; ') || 'none wrong'})`)
}

if (failures > 0) {
  console.log(`\nAUDIT_FAIL  (${failures} of ${checks} failed)`)
  process.exit(1)
}
// The coverage rides on the verdict line as well as above it: the suite keeps
// only the `<AREA>_PASS` line of each check, so a number that matters has to be
// in that one to be read.
const coverage = observedPath ? `  — ${compared} of ${claimed.size} cited counts compared` : ''
console.log(`\nAUDIT_PASS  (${checks} checks)${coverage}`)
