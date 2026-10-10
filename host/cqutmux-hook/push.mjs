// Remote push for cqutmux-hook.
//
// This is the host half of the APNs path. It is inert unless a signing key is
// configured, because a token-based APNs connection needs three things that
// only a paid Apple Developer account can produce:
//
//   --push-key   the .p8 signing key (APNs auth key)
//   --push-key-id  its 10-character Key ID
//   --push-team-id the 10-character Team ID
//
// Plus the app itself must be signed with a provisioning profile that carries
// the `aps-environment` entitlement; without that iOS never returns a device
// token, so `/push/register` is never called and there is nothing to send to.
// Until all of that exists, the gateway simply records tokens it never gets
// and logs why it is not pushing. The app's local notifications cover the same
// approvals while it is running, so nothing is silently lost.
//
// The protocol is APNs over HTTP/2 with a provider JWT. Node 22 has
// `http2` and `crypto` built in, so this needs no dependency — the JWT is
// ES256, which `crypto.sign('sha256', …, key)` produces directly.

import { connect } from 'node:http2'
import { sign } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { isActivityToken, payload as activityPayload, stamp, decide, tokenKindFor } from './liveactivity.mjs'

const APNS_HOST = 'https://api.push.apple.com'
const APNS_HOST_SANDBOX = 'https://api.sandbox.push.apple.com'

/** base64url, the only encoding JWT allows. */
function b64url(input) {
  return Buffer.from(input).toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

/**
 * The provider token APNs accepts in place of a password. Apple rejects
 * anything older than an hour, so it is regenerated on that cadence rather
 * than per request.
 */
export function providerToken({ key, keyId, teamId }) {
  const header = b64url(JSON.stringify({ alg: 'ES256', kid: keyId }))
  const claims = b64url(JSON.stringify({ iss: teamId, iat: Math.floor(Date.now() / 1000) }))
  const signingInput = `${header}.${claims}`
  // ES256 wants the raw r||s pair, which is what 'ieee-p1363' yields; the
  // default DER output is not what APNs expects and fails as a bad signature.
  const signature = sign('sha256', Buffer.from(signingInput), {
    key,
    dsaEncoding: 'ieee-p1363',
  })
  return `${signingInput}.${b64url(signature)}`
}

export function createPushService(args) {
  // Tokens are collected whether or not we can send, so that a gateway without
  // a key still reports "one device is registered and push is off" rather than
  // silently dropping registrations. That difference is the only way to tell a
  // misconfigured gateway from an app that never asked.
  const tokens = new Set()
  // Activity tokens are per-activity and short-lived, minted by the app when
  // it starts one; they are *not* device tokens and cannot be used for alerts.
  // Held separately because the two take different push types and a single
  // token sent down the wrong one is rejected.
  const activityTokens = new Set()
  // The app-level token, which is what lets a push *start* an activity on a
  // suspended phone. Distinct from the per-activity set above: that one can
  // only address an activity that already exists, and using it for a start is
  // a request APNs has nothing to attach to.
  const startTokens = new Set()
  const registerActivity = (token, kind = 'activity') => {
    if (!isActivityToken(token)) return false
    // `kind` is what the app sends: an app-level token and a per-activity one
    // are the same shape, so the set is chosen by what the caller says, not by
    // anything about the token itself.
    const set = kind === 'start' ? startTokens : activityTokens
    const isNew = !set.has(token)
    set.add(token)
    return isNew
  }
  // Removes from both sets: the app sends the token, not its kind, and the
  // shapes are identical — so a removal that only swept one set would leave the
  // other holding a token the user has turned off.
  const unregisterActivity = token => {
    const fromActivity = activityTokens.delete(token)
    const fromStart = startTokens.delete(token)
    return fromActivity || fromStart
  }
  const register = deviceToken => {
    if (!deviceToken || typeof deviceToken !== 'string' || !/^[0-9a-f]{64}$/i.test(deviceToken)) {
      return false
    }
    const isNew = !tokens.has(deviceToken)
    tokens.add(deviceToken)
    return isNew
  }

  const enabled = Boolean(args.pushKey && args.pushKeyId && args.pushTeamId)
  if (!enabled) {
    return { enabled: false, tokens, activityTokens, startTokens, register, registerActivity, unregisterActivity, notify: async () => {}, notifyActivity: async () => {} }
  }

  let key
  try {
    key = readFileSync(args.pushKey, 'utf8')
  } catch (error) {
    process.stderr.write(`[push] cannot read --push-key ${args.pushKey}: ${error.message}\n`)
    return { enabled: false, tokens, activityTokens, startTokens, register, registerActivity, unregisterActivity, notify: async () => {}, notifyActivity: async () => {} }
  }

  const host = args.pushSandbox ? APNS_HOST_SANDBOX : APNS_HOST
  const topic = args.pushTopic || 'app.cqutmux.ios'

  let cached = { token: '', at: 0 }
  function token() {
    const now = Date.now()
    if (!cached.token || now - cached.at > 50 * 60 * 1000) {
      cached = { token: providerToken({ key, keyId: args.pushKeyId, teamId: args.pushTeamId }), at: now }
    }
    return cached.token
  }

  let client
  function connection() {
    if (!client || client.closed || client.destroyed) client = connect(host)
    // An APNs connection error is asynchronous; without a listener Node treats
    // it as unhandled and takes the whole gateway down with it.
    client.on('error', error => process.stderr.write(`[push] connection: ${error.message}\n`))
    return client
  }

  /**
   * Sends one push. `payload` is the alert JSON; `eventId` rides in the
   * userInfo so a button press can name the approval it answers.
   */
  /**
   * One APNs request. Both the alert and the live-activity paths go through
   * here so the connection handling, the error listener and the dead-token
   * sweep exist once; `headers` is where the two differ.
   */
  function post(deviceToken, headers, body, onDead) {
    return new Promise(resolvePromise => {
      const request = connection().request({
        ':method': 'POST',
        ':path': `/3/device/${deviceToken}`,
        authorization: `bearer ${token()}`,
        ...headers,
      })

      let status = 0
      let reply = ''
      request.on('response', headers => { status = headers[':status'] })
      request.on('data', chunk => { reply += chunk })
      request.on('error', error => {
        process.stderr.write(`[push] ${error.message}\n`)
        resolvePromise(false)
      })
      request.on('end', () => {
        if (status === 200) return resolvePromise(true)
        process.stderr.write(`[push] ${status} ${reply}\n`)
        // 410 means the token is dead — the app was uninstalled or the token
        // rotated. Keeping it would mean pushing into the void forever.
        if (status === 410 || status === 400) onDead()
        resolvePromise(false)
      })
      request.end(body)
    })
  }

  /** Sends one alert push. */
  function send(deviceToken, alert, eventId) {
    return post(deviceToken, {
      'apns-topic': topic,
      'apns-push-type': 'alert',
      'apns-priority': '10',
    }, JSON.stringify({
      aps: {
        alert,
        sound: 'default',
        category: 'CQUT_APPROVAL',
        'mutable-content': 0,
      },
      eventId,
    }), () => tokens.delete(deviceToken))
  }

  return {
    enabled: true,
    tokens,
    activityTokens,
    startTokens,
    register,
    registerActivity,
    unregisterActivity,
    /**
     * Delivers a Live Activity start/update/end.
     *
     * `running` is passed in rather than tracked here: an activity is the
     * app's, and the gateway only learns it exists when the app says so. What
     * this needs from that is whether to say `start` or `update`, and getting
     * it wrong forks a duplicate or updates nothing.
     */
    async notifyActivity(record, { running = false, nowSeconds = Math.floor(Date.now() / 1000) } = {}) {
      const decision = decide(record, { running, pushToStart: startTokens.size > 0 })
      if (decision.action === 'none') return
      // A start is addressed to the app-level token and an update or end to the
      // per-activity one: they are different registrations, and sending a start
      // to an activity token is a request APNs has nothing to attach it to.
      const targets = tokenKindFor(decision.event) === 'start' ? startTokens : activityTokens
      if (!targets.size) return
      const built = stamp(activityPayload({
        action: decision.action,
        phase: decision.phase,
        event: decision.event,
        title: record.title || record.body || '',
        source: record.source || '',
        eventID: record.id,
      }), nowSeconds)
      const body = JSON.stringify(built.body)
      await Promise.all([...targets].map(t => post(t, {
        'apns-topic': built.headers['apns-topic'],
        'apns-push-type': built.headers['apns-push-type'],
        'apns-priority': built.headers['apns-priority'],
      }, body, () => activityTokens.delete(t))))
    },
    async notify(record) {
      if (!tokens.size) return
      const alert = {
        title: `${record.source} needs approval`,
        body: record.title || record.body || 'Open CQUTmux to answer.',
      }
      await Promise.all([...tokens].map(t => send(t, alert, record.id)))
    },
  }
}