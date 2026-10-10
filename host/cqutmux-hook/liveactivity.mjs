// Steering a Live Activity from the host.
//
// The app can keep a Live Activity in sync while it is running — it polls the
// inbox and starts, updates or ends the activity. The gap is everything the
// app cannot see: an approval that arrives while the phone is backgrounded or
// suspended, or a session that ends after the app was killed. Only a push can
// reach the device then, and a push that starts an activity is a different
// beast from an alert: it needs `apns-push-type: liveactivity`, an `event`
// key of `start` on the *first* one, and a per-activity token from the app
// rather than the device token.
//
// This module decides what a given event *should* do to an activity, and
// builds the payload. Both rules are quiet when wrong:
//
//   - An update for an activity that was never started is accepted by APNs and
//     dropped by the device, so a "working" event on a cold phone silently
//     does nothing. Choosing `none` there is the honest answer — the app will
//     raise the activity on its next poll — where a naive `upsert` would look
//     like it worked and be defined as "sent an update nobody saw".
//   - A `start` sent while an activity *is* running is rejected as a duplicate
//     (or worse, forks a second activity). So the decision depends on whether
//     one is already up, which is state the caller holds and this takes as an
//     argument.
//   - An `end` with no activity is a no-op that APNs answers with 200.
//
// No ActivityKit, no APNs, no clock — a pure function of (event, state) so the
// decision table can be checked exhaustively.

/**
 * A short-lived token APNs accepts for one activity, instead of the device
 * token. Apple's uppercase hex, the same alphabet as a device token.
 */
export function isActivityToken(token) {
  return typeof token === 'string' && /^[0-9a-f]{64}$/i.test(token)
}

/**
 * The phase one event puts an activity in.
 *
 * Deliberately the same vocabulary as the app's `ActivityPhase` — the two are
 * the same axis, and a host that invented its own names would make the phone
 * and the host disagree about what "done" is. `answer` (an approval that was
 * decided) is `tool_running`: allowing a tool lets it run, which is the same
 * reading the in-app `AgentActivityPreview` takes.
 *
 * An unknown kind is not a phase. Returning one anyway would start an activity
 * about a thing the host does not understand; nil lets the caller leave the
 * activity alone.
 */
export function phaseOf(event) {
  if (!event || typeof event !== 'object') return null
  // `endsSession` wins over the kind: it is the only final state, and letting
  // the carrying event's category decide instead would skip the linger.
  if (event.endsSession === true) return 'session_ended'
  switch (event.kind) {
    case 'approval': return 'approval_required'
    case 'answer': return 'tool_running'
    case 'tool': return 'tool_running'
    case 'tool_finished': return 'tool_running'
    case 'done': return 'task_complete'
    case 'session_started': return 'task_complete'
    default: return null
  }
}

/** The phases that dismiss rather than linger. */
export function isFinalPhase(phase) {
  return phase === 'session_ended'
}

/**
 * What an event should do to the activity.
 *
 * Returns `upsert`, `end` or `none`. `running` is whether an activity is
 * already up on the device; `pushToStart` is whether this app is allowed to
 * begin one from a push (the user can turn that off, and the system will not
 * let a start through when it is off).
 *
 * `none` is not a failure mode — it is the right answer for "there is nothing
 * this push can do", and the in-app poll is what covers those cases. Returning
 * `upsert` for them would mean claiming to have shown something on a Lock
 * Screen where nothing appeared.
 */
export function decide(event, { running = false, pushToStart = true } = {}) {
  // An explicit hint on the event wins over the guess made from its kind: the
  // agent that produced the event knows what it meant, and re-deriving that
  // from `kind` is a guess that can only agree or be wrong. `none` is the one
  // value that has to be honoured even when the derived answer would be to
  // push — it is how an event says "this one is not for the Lock Screen".
  // The hint rides in the event's `data` on the wire — that is the bag the
  // gateway stores verbatim and the hook fills — and is accepted at the top
  // level too so a caller can hand the decision the shape it already has.
  const hint = event && (event.liveActivity || (event.data && event.data.liveActivity))
  const steered = hint && hint.action
  if (steered === 'none') return { action: 'none', reason: 'steered' }

  // An explicit `end` is a lifecycle instruction rather than a phase, so it is
  // honoured even for an event whose kind has no phase of its own.
  if (steered === 'end') {
    if (!running) return { action: 'none', reason: 'nothing-to-end' }
    return { action: 'end', phase: 'session_ended' }
  }

  const phase = phaseOf(event)
  if (!phase) return { action: 'none', reason: 'unknown-kind' }

  // `upsert` is a request to put something up, not a decision about whether
  // one is already there — that still comes from `running`, or the payload
  // would say `start` when an activity is up and fork a duplicate.
  const forceUpsert = steered === 'upsert'

  if (isFinalPhase(phase)) {
    // Nothing to end is a no-op, and asking APNs to end an activity that is
    // not there is a request whose 200 means nothing happened.
    if (!running) return { action: 'none', reason: 'nothing-to-end' }
    return { action: 'end', phase }
  }

  if (running) return { action: 'upsert', phase, event: 'update' }

  // Nothing up. A push may only *start* one where the app allows it and the
  // user has not revoked the capability; otherwise the poll covers it.
  if (!pushToStart && !forceUpsert) return { action: 'none', reason: 'push-to-start-off' }
  return { action: 'upsert', phase, event: 'start' }
}

/**
 * Which registration a push must be addressed to.
 *
 * `start` and `update`/`end` go to *different* tokens, and they are not
 * interchangeable: a start needs the app-level push-to-start token, an update
 * needs the per-activity token minted with the activity. Sending a start to an
 * activity token is a request APNs accepts and the device has nothing to attach
 * to — an activity that silently never appears.
 *
 * Named from the caller's side (`event` is the same `start`/`update` the
 * payload carries) so the two cannot drift apart.
 */
export function tokenKindFor(event) {
  return event === 'start' ? 'start' : 'activity'
}

/**
 * The APNs payload for a Live Activity, alongside the headers it needs.
 *
 * The shape is Apple's: `aps.timestamp` is *seconds*, not milliseconds, and is
 * what the system uses to order updates — a payload without it is accepted and
 * then dropped, which is the failure this exists to avoid. `aps.event` is
 * `start` only on the first push; every later one omits it. `alert` carries
 * the text the Lock Screen renders, matching the fields the app's own
 * `ContentState` decodes.
 */
export function payload({ action, phase, event, hostName, title, source, pending, eventID }) {
  const bundle = 'app.cqutmux.ios'
  const headers = {
    'apns-push-type': 'liveactivity',
    'apns-priority': '10',
    'apns-topic': `${bundle}.push-type.liveactivity`,
  }
  const aps = { 'content-state': contentState({ phase, title, source, pending, eventID }) }

  if (action === 'end') {
    aps.event = 'end'
    return { headers, body: { aps } }
  }

  aps.event = event === 'start' ? 'start' : 'update'
  // An approval outranks a finished tool call, so the Lock Screen keeps the
  // raised hand above the hammer. Without a score the system orders two
  // simultaneous activities by name, which is not what either is about.
  aps['relevance-score'] = phase === 'approval_required' ? 100 : 50
  aps.alert = { title: alertTitle(phase, source), body: title || 'Open CQUTmux.' }
  // `attributes-type` and `attributes` ride only on the *first* push: the
  // system takes the static half of the activity from here and rejects a
  // second start, and sending `start` on an update is how a duplicate activity
  // gets created.
  if (event === 'start') {
    aps['attributes-type'] = 'AgentActivityAttributes'
    aps.attributes = { hostName: hostName || 'host' }
  }

  return { headers, body: { aps } }
}

/**
 * The `content-state` the widget decodes. Field names and the phase strings
 * match `AgentActivityAttributes.ContentState` and `ActivityPhase` exactly —
 * the widget decodes this struct, and a renamed field decodes to a *default*
 * rather than throwing for the optional ones, so a mismatch renders an
 * activity that is silently about nothing.
 */
function contentState({ phase, title, source, pending, eventID }) {
  return {
    pending: Number.isFinite(pending) ? pending : (phase === 'approval_required' ? 1 : 0),
    phase: phase || 'approval_required',
    latestTitle: title || 'Agent',
    latestSource: source || 'Agent',
    // The approval the Lock Screen buttons will answer. It has to be the real
    // gateway id — the widget passes it straight back — so a phase that asks
    // nothing, or a caller that does not know one, sends 0 rather than a guess
    // that would decide some other approval.
    latestEvent: phase === 'approval_required' && Number.isInteger(eventID) ? eventID : 0,
  }
}

/**
 * The alert line. Only the start push carries one — an update updates the
 * activity in place and shows no banner — so this is written for the two cases
 * that begin an activity.
 */
function alertTitle(phase, source) {
  if (phase === 'session_ended') return 'Session ended'
  return `${source || 'Agent'} needs approval`
}

/**
 * Fills in the payload's timestamps from a real clock.
 *
 * Split out so `payload` stays a pure function of its arguments — a payload
 * built with `Date.now()` inside cannot be compared against an expected one in
 * a check, and the field that most often goes wrong here is exactly this one:
 * APNs wants `timestamp` in *seconds*, and a millisecond value is accepted and
 * then silently ignored as stale.
 *
 * An `end` gets a dismissal date of the same instant — it is going away now.
 * A final phase on a start/update gets one `staleSeconds` out, which is the
 * linger that lets the user read *that the session ended* rather than watching
 * the activity vanish.
 */
export function stamp(result, nowSeconds, staleSeconds = 900) {
  const now = Math.floor(nowSeconds)
  const body = structuredClone(result.body)
  body.aps.timestamp = now
  if (body.aps.event === 'end') {
    body.aps['dismissal-date'] = now
  } else if (isFinalPhase(phaseOfPayload(body))) {
    body.aps['dismissal-date'] = now + Math.floor(staleSeconds)
  } else {
    body.aps['stale-date'] = now + Math.floor(staleSeconds)
  }
  return { ...result, body }
}

/** The phase a payload's content-state carries, for the dismissal decision. */
function phaseOfPayload(body) {
  return body?.aps?.['content-state']?.phase
}
