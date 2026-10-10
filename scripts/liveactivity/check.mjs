// What a push should do to a Live Activity, and what it should carry.
//
// Every rule here is quiet when wrong. An update for an activity that was
// never started is accepted by APNs and dropped by the device, so "sent" and
// "shown" are different things; a `start` on an activity that is already up
// forks a duplicate; a millisecond `timestamp` is accepted and ignored as
// stale. None of that is visible without a device, so the decision table is
// checked exhaustively instead.

import {
  isActivityToken, phaseOf, isFinalPhase, decide, payload, stamp, tokenKindFor,
} from '../../host/cqutmux-hook/liveactivity.mjs'

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

// MARK: - Activity tokens

check(isActivityToken('a'.repeat(64)), 'a 64-hex activity token is accepted')
check(isActivityToken('A1'.repeat(32)), 'uppercase hex is accepted')
check(!isActivityToken('a'.repeat(63)), 'a short token is refused')
check(!isActivityToken('z'.repeat(64)), 'a non-hex token is refused')
check(!isActivityToken(''), 'an empty token is refused')
check(!isActivityToken(null), 'a missing token is refused')

// MARK: - Phases

check(phaseOf({ kind: 'approval' }) === 'approval_required', 'an approval asks')
check(phaseOf({ kind: 'done' }) === 'task_complete', 'a finished turn is done')
check(phaseOf({ kind: 'tool' }) === 'tool_running', 'a running tool is working')
// An answered approval is tool_running, not done: allowing a tool lets it run.
check(phaseOf({ kind: 'answer' }) === 'tool_running', 'an answered approval is working')

// session_ended wins over whatever the carrying event's kind would say, or the
// linger would be skipped and the activity yanked the instant the agent stops.
check(phaseOf({ kind: 'done', endsSession: true }) === 'session_ended',
      'a session ending wins over the event kind')
check(phaseOf({ kind: 'approval', endsSession: true }) === 'session_ended',
      'and over an approval, which is the case that would otherwise linger wrongly')

// An unknown kind is not a phase. Inventing one would start an activity about
// something the host does not understand.
check(phaseOf({ kind: 'who-knows' }) === null, 'an unknown kind has no phase')
check(phaseOf({}) === null, 'a missing kind has no phase')
check(phaseOf(null) === null, 'a missing event has no phase')

// The phase strings are the app's: `ActivityPhase` decodes these exact values,
// and a mismatch makes the widget fall back to a default rather than throw.
check(phaseOf({ kind: 'approval' }) === 'approval_required'
      && phaseOf({ kind: 'done' }) === 'task_complete'
      && phaseOf({ kind: 'tool' }) === 'tool_running'
      && phaseOf({ kind: 'x', endsSession: true }) === 'session_ended',
      'the phase strings are ActivityPhase\'s raw values')

check(isFinalPhase('session_ended'), 'session_ended is final')
check(!isFinalPhase('task_complete'), 'done is not final — it lingers, it does not dismiss')
check(!isFinalPhase('approval_required'), 'an approval is not final')

// MARK: - The decision table

const approval = { kind: 'approval' }
const done = { kind: 'done' }
const ended = { kind: 'done', endsSession: true }

// Nothing running, push-to-start allowed: the push begins the activity. This is
// the case the feature exists for — an approval arriving on a suspended phone.
check(decide(approval, { running: false, pushToStart: true }).action === 'upsert'
      && decide(approval, { running: false, pushToStart: true }).event === 'start',
      'an approval with nothing up starts an activity')

// Running: update, never a second start.
check(decide(approval, { running: true }).event === 'update',
      'an approval with an activity up updates rather than starts')
check(decide(done, { running: true }).action === 'upsert', 'a done event updates the activity')

// Push-to-start off: nothing can begin an activity, and saying "upsert" would
// claim a Lock Screen entry that never appeared. The poll covers it.
check(decide(approval, { running: false, pushToStart: false }).action === 'none',
      'with push-to-start off nothing starts one')
check(decide(approval, { running: false, pushToStart: false }).reason === 'push-to-start-off',
      'and it says why, rather than failing silently')
// But an activity already up can still be updated — turning off *starting* is
// not turning off updating, or the activity would freeze mid-session.
check(decide(approval, { running: true, pushToStart: false }).action === 'upsert',
      'push-to-start off still allows updating a running activity')

// Ending: only when there is something to end.
check(decide(ended, { running: true }).action === 'end',
      'a session ending ends the activity that is up')
check(decide(ended, { running: false }).action === 'none',
      'a session ending with nothing up does nothing')
check(decide(ended, { running: false }).reason === 'nothing-to-end',
      'and says there was nothing to end')
// An end does not need push-to-start: it is not starting anything.
check(decide(ended, { running: true, pushToStart: false }).action === 'end',
      'push-to-start off does not block ending')

check(decide({ kind: 'nonsense' }, { running: true }).action === 'none',
      'an unknown kind does nothing even with an activity up')

// The default state is "nothing running, push-to-start allowed" — the check
// that the caller which forgets to pass state gets the safe branch.
check(decide(approval).event === 'start', 'the default state allows a start')

// MARK: - The event's own hint

// An explicit `none` is honoured even where the kind would otherwise push: it
// is how an event says "this one is not for the Lock Screen", and overriding it
// would put something up the agent deliberately held back.
check(decide({ kind: 'approval', liveActivity: { action: 'none' } }, { running: true }).action === 'none',
      'an explicit none beats a kind that would otherwise update')
check(decide({ kind: 'done', liveActivity: { action: 'none' } }, { running: false }).action === 'none',
      'and beats one that would otherwise start')

// An explicit `end` is a lifecycle instruction, so it ends an activity even for
// an event whose kind has no phase of its own.
check(decide({ kind: 'who-knows', liveActivity: { action: 'end' } }, { running: true }).action === 'end',
      'an explicit end ends an activity regardless of the kind')
check(decide({ kind: 'who-knows', liveActivity: { action: 'end' } }, { running: false }).action === 'none',
      'an explicit end with nothing up still does nothing')

// An explicit `upsert` on a kind that has no phase is *not* a licence to invent
// one — the payload has to name a phase from the app's vocabulary, and there is
// nothing to name.
check(decide({ kind: 'who-knows', liveActivity: { action: 'upsert' } }, { running: true }).action === 'none',
      'an explicit upsert without a known kind still has no phase to show')

// `upsert` does override push-to-start: it is a direct instruction rather than
// the guess from the kind.
check(decide({ kind: 'approval', liveActivity: { action: 'upsert' } },
             { running: false, pushToStart: false }).action === 'upsert',
      'an explicit upsert overrides push-to-start being off')

// An explicit `upsert` with something already up is still an update, not a
// second start — the hint says *what*, not *start or update*.
check(decide({ kind: 'approval', liveActivity: { action: 'upsert' } }, { running: true }).event === 'update',
      'an explicit upsert on a running activity updates rather than starts')

// The hint arrives inside `data` on the wire, which is where the gateway puts
// what a hook sends. Reading only the top level would make every steering
// instruction silently ignored.
check(decide({ kind: 'approval', data: { liveActivity: { action: 'none' } } }, { running: true }).action === 'none',
      'a none hint inside data is honoured')
check(decide({ kind: 'x', data: { liveActivity: { action: 'end' } } }, { running: true }).action === 'end',
      'an end hint inside data is honoured')

// MARK: - Which token a push goes to

// A start is addressed to the app-level push-to-start token; an update or end
// to the per-activity one. Sending a start to an activity token is accepted by
// APNs and attaches to nothing, so the activity never appears.
check(tokenKindFor('start') === 'start', 'a start goes to the push-to-start token')
check(tokenKindFor('update') === 'activity', 'an update goes to the activity token')
check(tokenKindFor('end') === 'activity', 'an end goes to the activity token')
// Anything unexpected is treated as an update, which is the safe failure: an
// update to a token that does not exist is dropped, where a stray start would
// create a second activity.
check(tokenKindFor(undefined) === 'activity', 'an unknown event is treated as an update')

// MARK: - Payloads

const start = payload({
  action: 'upsert', phase: 'approval_required', event: 'start',
  hostName: 'devbox', title: 'Run rm -rf build/', source: 'claude', pending: 2,
})

check(start.headers['apns-push-type'] === 'liveactivity',
      'a live activity push is of type liveactivity, not alert')
check(start.headers['apns-topic'].endsWith('.push-type.liveactivity'),
      'and goes to the push-type topic')
check(start.body.aps.event === 'start', 'the first push says start')
check(start.body.aps['attributes-type'] === 'AgentActivityAttributes',
      'and names the attributes type the widget decodes')
check(start.body.aps.attributes.hostName === 'devbox', 'and carries the static host name')

// The content-state field names are the widget's. A renamed one decodes to a
// default rather than throwing, so a mismatch is an activity about nothing.
const state = start.body.aps['content-state']
check(state.pending === 2 && state.phase === 'approval_required'
      && state.latestTitle === 'Run rm -rf build/' && state.latestSource === 'claude',
      'the content-state matches ContentState field for field')
check(start.body.aps['relevance-score'] === 100,
      'an approval scores above a working update')

// The id the Lock Screen buttons answer. It has to be the real gateway id or a
// tap decides some other approval — and 0 for a phase that asks nothing, since a
// button on a "working" activity would be answering a question nobody asked.
const withID = payload({
  action: 'upsert', phase: 'approval_required', event: 'start',
  title: 'T', source: 'claude', pending: 1, eventID: 42,
})
check(withID.body.aps['content-state'].latestEvent === 42,
      'an approval carries the event id its buttons will answer')

const noID = payload({ action: 'upsert', phase: 'approval_required', event: 'start',
                       title: 'T', source: 'claude', pending: 1 })
check(noID.body.aps['content-state'].latestEvent === 0,
      'an approval with no id known sends 0 rather than a guess')

const working = payload({ action: 'upsert', phase: 'tool_running', event: 'update',
                          title: 'T', source: 'claude', eventID: 42 })
check(working.body.aps['content-state'].latestEvent === 0,
      'a working phase carries no id, so no button answers anything')

const update = payload({
  action: 'upsert', phase: 'tool_running', event: 'update',
  title: 'Edit App.swift', source: 'codex', pending: 0,
})
check(update.body.aps.event === 'update', 'a later push says update')
// The one that matters: sending `start` here creates a second activity.
check(update.body.aps['attributes-type'] === undefined,
      'an update carries no attributes, which would fork a second activity')
check(update.body.aps['relevance-score'] === 50, 'a working update scores lower')

const end = payload({ action: 'end', phase: 'session_ended', title: 'x', source: 'claude' })
check(end.body.aps.event === 'end', 'an end says end')
check(end.body.aps.alert === undefined, 'and carries no alert — there is nothing to read')

// Defaults for an event with no title: a blank line reads as a rendering bug.
const bare = payload({ action: 'upsert', phase: 'approval_required', event: 'start' })
check(bare.body.aps['content-state'].latestTitle === 'Agent',
      'a missing title falls back to a word, not a blank line')
check(bare.body.aps['content-state'].latestSource === 'Agent', 'and so does a missing source')
check(bare.body.aps['content-state'].pending === 1,
      'an approval with no count still counts as one waiting')
check(bare.body.aps.attributes.hostName === 'host', 'a missing host name has a fallback')

// MARK: - Stamping

const now = 1_700_000_000
const stamped = stamp(start, now)
// Seconds, not milliseconds: APNs takes `timestamp` in seconds and a
// millisecond value is accepted and then ignored as stale.
check(stamped.body.aps.timestamp === now, 'the timestamp is the seconds value given')
check(stamped.body.aps.timestamp < 10_000_000_000, 'and is seconds, not milliseconds')
check(stamped.body.aps['stale-date'] === now + 900, 'a working activity goes stale on the default window')

const stampedEnd = stamp(end, now)
check(stampedEnd.body.aps['dismissal-date'] === now,
      'an end dismisses now rather than lingering')

const stampedFinal = stamp(
  payload({ action: 'upsert', phase: 'session_ended', event: 'update', title: 'x', source: 'c' }),
  now, 300,
)
check(stampedFinal.body.aps['dismissal-date'] === now + 300,
      'a final phase lingers for the window before dismissing')
check(stampedFinal.body.aps['stale-date'] === undefined,
      'and has no stale date, because it is going away anyway')

// The pure function is not mutated: stamping twice from one payload has to give
// the same thing, or a retry would send a different time than the first try.
const first = stamp(start, now).body.aps.timestamp
const second = stamp(start, now + 50).body.aps.timestamp
check(first === now && second === now + 50,
      'stamping leaves the original payload alone')

if (failures > 0) {
  console.log(`\nLIVEACTIVITY_FAIL  (${failures} of ${checks} failed)`)
  process.exit(1)
}
console.log(`\nLIVEACTIVITY_PASS  (${checks} checks)`)
