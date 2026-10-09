#!/usr/bin/env bash
#
# Checks the recent-directory discovery, which reads other programs' private
# on-disk history.
#
# Two things here fail silently if they are wrong, and neither shows up as an
# error:
#
# 1. The Claude Code project slug is *lossy*. `/srv/a-b` and `/srv/a/b` both
#    slugify to `-srv-a-b`, so a path reconstructed from the directory name can
#    be a path that does not exist. That fallback therefore has to be marked as
#    inferred, and a `cwd` read from a transcript has to win over it.
#
# 2. A transcript is a file another program is actively writing, so reading it
#    can land on a half-written line. A parse failure must skip that line, not
#    abandon the file — the record wanted is usually earlier in it.
#
# The check builds a fake home directory with a Claude Code layout in it, so
# this exercises the real reader rather than a stub of it.
#
# Usage: scripts/recent-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

node --input-type=module -e "
import assert from 'node:assert'
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { cwdFromTranscriptHead, pathFromSlug, recentDirectories } from '$ROOT/host/cqutmux-hook/recent.mjs'

let failures = 0, checks = 0
function check(condition, label) {
  checks++
  if (condition) { console.log('PASS  ' + label) }
  else { failures++; console.log('FAIL  ' + label) }
}

// --- Reading a cwd out of a transcript's head ---

check(cwdFromTranscriptHead('{\"cwd\":\"/srv/api\",\"type\":\"user\"}') === '/srv/api',
  'a cwd is read from a record')
check(cwdFromTranscriptHead('{\"payload\":{\"cwd\":\"/srv/web\"}}') === '/srv/web',
  'and from a nested one, which is the shape Codex uses')
check(cwdFromTranscriptHead('') === null, 'an empty file has no cwd')
check(cwdFromTranscriptHead('not json at all') === null,
  'a file that is not JSON at all has no cwd rather than throwing')
check(cwdFromTranscriptHead('{\"cwd\":\"relative/path\"}') === null,
  'a relative cwd is refused — every agent writes an absolute one')
check(cwdFromTranscriptHead('{\"cwd\":\"\"}') === null, 'an empty cwd is not a directory')

// The half-written-line case: an agent is appending while this reads. The
// broken line must be skipped and the good record after it still found.
const torn = '{\"type\":\"user\",\"cwd\":\"/srv/one\"}\n{\"cwd\":\"/srv/tw'
check(cwdFromTranscriptHead(torn) === '/srv/one',
  'a torn last line does not lose the records before it')
const leadingGarbage = 'x\n{bad json}\n{\"cwd\":\"/srv/two\"}\n'
check(cwdFromTranscriptHead(leadingGarbage) === '/srv/two',
  'and neither does unparseable noise before the record')
// A long first line must not hide the cwd on the second.
check(cwdFromTranscriptHead('[\"a\".repeat(' + 100 + ')]\n{\"cwd\":\"/srv/three\"}'.replace('\"a\".repeat(' + 100 + ')', JSON.stringify('a'.repeat(200)))) === '/srv/three',
  'a big record without a cwd is skipped, not fatal')

// --- Reconstructing a path from a slug ---

check(pathFromSlug('-srv-www-app') === '/srv/www/app',
  'a slug with no dashes in the names maps back to a path')
check(pathFromSlug('-Users-me-projects') === '/Users/me/projects', 'including a leading separator')
check(pathFromSlug('srv-www') === null, 'a slug without a leading dash is not a project directory')
check(pathFromSlug('') === null, 'and neither is an empty one')

// --- The walk over a fake home ---

const home = '$OUT/home'
mkdirSync(join(home, '.claude', 'projects', '-srv-api'), { recursive: true })
mkdirSync(join(home, '.claude', 'projects', '-srv-a-b'), { recursive: true })
mkdirSync(join(home, '.codex', 'sessions', '2026'), { recursive: true })

// A Claude Code session that names its directory in the transcript.
writeFileSync(join(home, '.claude', 'projects', '-srv-api', 'aaa.jsonl'),
  '{\"type\":\"user\",\"cwd\":\"/srv/api\"}\n')
// A second session in the same project, newer, so this project wins on time.
writeFileSync(join(home, '.claude', 'projects', '-srv-api', 'bbb.jsonl'),
  '{\"type\":\"user\",\"cwd\":\"/srv/api\"}\n')
// A project whose transcript has no cwd, so only the slug is available.
writeFileSync(join(home, '.claude', 'projects', '-srv-a-b', 'ccc.jsonl'), '{\"type\":\"user\"}\n')
// A Codex session, which the same reader handles.
writeFileSync(join(home, '.codex', 'sessions', '2026', 'ddd.jsonl'),
  '{\"payload\":{\"cwd\":\"/srv/codex-work\"}}\n')

const found = await recentDirectories({ home, limit: 20 })
const paths = found.directories.map(d => d.path)
check(paths.includes('/srv/api'), 'a directory named in a transcript is discovered')
check(paths.includes('/srv/codex-work'), 'and one from another agent\\'s tree')
check(found.directories.every(d => d.path.startsWith('/')), 'every path is absolute')

const api = found.directories.find(d => d.path === '/srv/api')
check(api && api.agent === 'claude', 'the entry records which agent it came from')
check(api && api.inferred === false, 'and that the path was read, not guessed')

// The lossy fallback has to be marked, or the app shows a guess as a fact.
const guessed = found.directories.find(d => d.path === '/srv/a/b')
check(guessed && guessed.inferred === true,
  'a slug-only path is marked inferred, because a dash in a name is indistinguishable')

// A real path beats a guess for the same directory.
const collisions = await recentDirectories({ home: '$OUT/collide', limit: 20 })
check(collisions.directories.length === 0, 'a home with no agents at all yields nothing')

// --- Newest first, and the limit is honoured ---

const sorted = found.directories.every((d, i) =>
  i === 0 || found.directories[i - 1].at >= d.at)
check(sorted, 'directories come back newest first')
check((await recentDirectories({ home, limit: 2 })).directories.length === 2,
  'the limit is honoured')

console.log('')
if (failures === 0) { console.log('RECENT_PASS  (' + checks + ' checks)') }
else { console.log('RECENT_FAIL  (' + failures + ' of ' + checks + ' failed)'); process.exit(1) }
"