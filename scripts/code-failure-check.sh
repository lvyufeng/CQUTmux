#!/usr/bin/env bash
#
# Checks that the Code panel says why something did not load.
#
# There were three ways it said nothing, and each looked like a different bug:
# a file over the gateway's half-megabyte limit opened no sheet and showed no
# message, a diff or a log that failed to load left a spinner turning forever,
# and a change too large for the host's buffer came back as "This directory
# isn't under version control" — the one answer that tells the user to stop
# looking. None of the three is a wrong answer; all are the absence of one.
#
# The wire half runs against a real gateway and a throwaway repository, because
# the interesting failure is a *branch*: a bare catch that cannot tell a missing
# repository from an oversized diff. Asserting the branch by grepping for it
# would pass against a tree where both paths returned the same thing.
#
# Usage: scripts/code-failure-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GATEWAY_PORT="${CQUTMUX_GATEWAY_PORT:-24673}"
TOKEN="code-failure-test"

WORK="$(mktemp -d)"
cleanup() { [[ -n "${GW_PID:-}" ]] && kill "$GW_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# The gateway's root is *not* the repository. It has to be a plain directory
# with the repository inside it, or the "not a repository" case cannot be built
# at all: git searches upward for `.git`, so any subdirectory of the fixture
# repo is inside the repo and answers as one.
echo "==> building a repository with a change too large to read"
mkdir -p "$WORK/not-a-repo"
cd "$WORK/repo" 2>/dev/null || { mkdir -p "$WORK/repo"; cd "$WORK/repo"; }
git init -q .
git config commit.gpgsign false
git config user.email "check@example.com"
git config user.name "Check"

# One enormous line, then a different enormous line, left *uncommitted*: `git
# diff` compares the working tree against the index, so a repository whose
# changes have all been committed has no diff at all — which is what the first
# draft of this check measured.
python3 -c "print('a' * 5000000)" > huge.txt
printf 'small change\n' > small.txt
# Tracked and committed so it stays out of the size test, and over the /file
# limit so the other route has something to refuse.
python3 -c "print('c' * 600000)" > big.txt
git add -A
git commit -q -m first

python3 -c "print('b' * 5000000)" > huge.txt
printf 'small change, edited\n' > small.txt

cd "$ROOT"
echo "==> starting the gateway"
node host/cqutmux-hook/index.mjs --port "$GATEWAY_PORT" --token "$TOKEN" --root "$WORK" \
  >/dev/null 2>&1 &
GW_PID=$!
sleep 2

ROOT="$ROOT" PORT="$GATEWAY_PORT" TOKEN="$TOKEN" node --input-type=module - <<'JS'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const root = process.env.ROOT
const port = process.env.PORT
const token = process.env.TOKEN

let checks = 0
let failures = 0
function check(condition, label) {
  checks += 1
  if (condition) console.log(`PASS  ${label}`)
  else { failures += 1; console.log(`FAIL  ${label}`) }
}

async function get(path) {
  const response = await fetch(`http://127.0.0.1:${port}${path}`, {
    headers: { authorization: `Bearer ${token}` },
  })
  let body = null
  try { body = await response.json() } catch { /* not every answer is JSON */ }
  return { status: response.status, body }
}

console.log('\n— a change too large is refused, not reported as no repository —')

const huge = await get('/diff?path=repo&file=huge.txt')
check(huge.status === 413, `an oversized change is refused (got ${huge.status})`)
check(typeof huge.body?.error === 'string' && /MB/.test(huge.body.error),
      `and the refusal names the limit: ${JSON.stringify(huge.body?.error)}`)
check(!/version control/i.test(JSON.stringify(huge.body)),
      'it does not tell the user the directory is not a repository')

// The whole-tree diff goes through the same call, and used to answer with the
// same empty-repository shape rather than an error.
const whole = await get('/diff?path=repo')
check(whole.status === 413, `the whole-tree diff refuses the same way (got ${whole.status})`)

console.log('\n— and the two answers it was confused with still work —')

// The branch that was added must not swallow the real answers: a small diff is
// still a 200 with a diff in it, and a directory that is not a repository is
// still `isRepo: false` rather than an error.
const small = await get('/diff?path=repo&file=small.txt')
check(small.status === 200, `a small change still loads (got ${small.status})`)
check(small.body?.isRepo === true && small.body.diff.includes('small change'),
      'and carries its diff')

const absent = await get('/diff?path=not-a-repo')
check(absent.status === 200 && absent.body?.isRepo === false,
      `a directory that is not a repository still says so (got ${absent.status})`)

console.log('\n— a file over the limit says how far over —')

const big = await get('/file?path=repo/big.txt')
check(big.status === 413, `an oversized file is refused (got ${big.status})`)
check(typeof big.body?.error === 'string' && /KB/.test(big.body.error),
      `and the message names the limit: ${JSON.stringify(big.body?.error)}`)

const fine = await get('/file?path=repo/small.txt')
check(fine.status === 200 && typeof fine.body?.content === 'string',
      'a file under the limit still opens')

console.log('\n— the app does not throw the answer away —')

const panel = readFileSync(join(root, 'App/Features/Code/CodePanelView.swift'), 'utf8')
const client = readFileSync(join(root, 'App/Features/Agents/HookClient.swift'), 'utf8')

// `try?` is how all three refusals became nothing: the failure was not
// mishandled, it was discarded, and there is no state left to draw.
for (const call of ['readFile', 'gitDiff', 'gitLog']) {
  check(!panel.includes(`try? await client.${call}(`),
        `the panel does not discard a failed ${call}`)
}

// The two the user can act on have somewhere to land. A failure that sets no
// state is the same as one that was never caught.
for (const [state, label] of [['diffProblem', 'the changes'],
                              ['logProblem', 'the history'],
                              ['openProblem', 'a file that would not open']]) {
  check(panel.includes(state), `${label} has a failure state`)
}
check(/\.alert\("Couldn't open that file"/.test(panel),
      'a file that will not open raises an alert rather than replacing the list')

// The browse methods refuse a non-200 rather than handing the error body to
// the decoder, which would report `keyNotFound` — the app's word for it, not
// the user's.
const checks_ = (client.match(/try checked\(payload\)/g) || []).length
check(checks_ >= 7,
      `every browse call checks its status (found ${checks_}, expected at least 7)`)

if (failures > 0) {
  console.log(`\nCODE_FAILURE_FAIL  (${failures} of ${checks} failed)`)
  process.exit(1)
}
console.log(`\nCODE_FAILURE_PASS  (${checks} checks)`)
JS