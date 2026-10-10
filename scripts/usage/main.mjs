// The per-agent usage-window rules, checked with plain node.
//
// The board answers one question — "can I keep working on this agent?" — and it
// answers it with numbers derived from the windows. A window that is the wrong
// length, or a cap that does not match the agent, produces a plausible ring that
// is simply wrong, and nothing on screen would say so. So the shapes are asserted
// here rather than eyeballed.

import { windowsFor, windowsForSource, humanize, HOUR, DAY } from '../../host/cqutmux-hook/usage.mjs'

let failures = 0
let checks = 0
function check(condition, label) {
  checks += 1
  if (condition) { console.log(`PASS  ${label}`) }
  else { failures += 1; console.log(`FAIL  ${label}`) }
}

const labels = source => windowsFor(source).map(w => w.label).join(',')

console.log('— each agent gets its own shape —')
// One set for every agent is the bug this replaces: it states Claude's limits on
// behalf of an agent that has different ones.
check(labels('claude-code') === '5h,7d', `Claude Code has fixed 5h and 7d windows (got ${labels('claude-code')})`)
check(labels('codex') === '5h,weekly', `Codex uses human labels, not "7d" (got ${labels('codex')})`)
check(labels('kimi-code') === 'weekly', `Kimi Code has a weekly window (got ${labels('kimi-code')})`)
check(labels('grok-build') === 'credits', `Grok Build has a credit window (got ${labels('grok-build')})`)
check(labels('opencode') === 'rolling', `OpenCode has one rolling window (got ${labels('opencode')})`)

// The point of the whole change: at least two agents differ.
check(labels('claude-code') !== labels('codex'), 'Claude Code and Codex do not share a window set')
check(labels('claude-code') !== labels('kimi-code'), 'nor do Claude Code and Kimi')

console.log('\n— a credit window says so —')
// A credit balance is not a rate over time, so the app has to be able to render
// it as credits rather than as a percentage of a limit. The flag is the only
// thing that carries that.
const grok = windowsForSource('grok-build', [], 0)
check(grok.length === 1 && grok[0].credit === true, 'the Grok window is flagged as credit')
check(!windowsForSource('claude-code', [], 0).some(w => w.credit), 'a rate window is not')
check(!windowsForSource('codex', [], 0).some(w => w.credit), 'nor is Codex\'s weekly window')

console.log('\n— an agent we do not model still gets a board —')
// An empty card reads as "no usage", which is a different and false statement;
// the fallback states the shape we do know.
const unknown = windowsFor('some-new-agent')
check(unknown.length === 2, `an unknown agent falls back to a real window set (got ${unknown.length})`)
check(unknown === windowsFor('claude-code'), 'and it is Claude\'s, the shape the board shipped with')
check(unknown.map(w => w.label).join(',') === '5h,7d', 'with the labels the app already renders')

console.log('\n— measuring against the window —')
const now = 1_700_000_000_000
const claudeWindows = windowsFor('claude-code')
const cap5h = claudeWindows[0].cap

// Empty: zero, and a null reset (there is nothing to age out).
const empty = windowsForSource('claude-code', [], now)
check(empty.length === 2, 'both Claude windows are measured')
check(empty[0].percent === 0, 'no events is zero percent')
check(empty[0].resetIn === null, 'and no reset time, because nothing is in the window')

// Events inside the window count; events outside it do not.
const inWindow = Array.from({ length: cap5h / 2 }, (_, i) => now - i * 1000)
const half = windowsForSource('claude-code', inWindow, now)
check(half[0].percent === 50, `half the cap is 50% (got ${half[0].percent})`)
check(typeof half[0].resetIn === 'string', 'and a reset time, because events are in the window')

const stale = [now - 6 * HOUR]
const aged = windowsForSource('claude-code', stale, now)
check(aged[0].percent === 0, 'an event older than the window does not count')
check(aged[1].percent > 0, 'but it still counts against the 7d window')
check(aged[0].resetIn === null, 'and the emptied window has no reset')

// Over the cap is capped: a ring cannot draw past full, so 140% has nowhere to go.
const over = Array.from({ length: cap5h + 50 }, (_, i) => now - i * 1000)
check(windowsForSource('claude-code', over, now)[0].percent === 100, 'over the cap reads 100%, not more')

console.log('\n— the reset reads as a time —')
check(humanize(0) === 'now', 'a finished window resets now')
check(humanize(-5) === 'now', 'and so does a negative remainder')
check(humanize(90 * 60 * 1000) === '1h 30m', `90 minutes reads 1h 30m (got ${humanize(90 * 60 * 1000)})`)
check(humanize(45 * 60 * 1000) === '45m', 'under an hour reads in minutes')
// 59.6m must carry into the hour, not print "4h 60m".
check(humanize(4 * HOUR + 59.6 * 60 * 1000) === '5h 0m', `rounding carries (got ${humanize(4 * HOUR + 59.6 * 60 * 1000)})`)

// A per-agent window length is used, not Claude's: a Codex weekly window keeps an
// event that Claude's 5h window would have dropped.
const days3 = [now - 3 * DAY]
check(windowsForSource('claude-code', days3, now)[0].percent === 0, 'a 3-day-old event is outside Claude\'s 5h window')
check(windowsForSource('codex', days3, now)[1].percent > 0, 'but inside Codex\'s weekly one')

if (failures > 0) {
  console.log(`\nUSAGE_FAIL  (${failures} of ${checks} failed)`)
  process.exit(1)
}
console.log(`\nUSAGE_PASS  (${checks} checks)`)
