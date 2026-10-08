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
    return { enabled: false, tokens, register, notify: async () => {} }
  }

  let key
  try {
    key = readFileSync(args.pushKey, 'utf8')
  } catch (error) {
    process.stderr.write(`[push] cannot read --push-key ${args.pushKey}: ${error.message}\n`)
    return { enabled: false, tokens, register, notify: async () => {} }
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
  function send(deviceToken, alert, eventId) {
    return new Promise(resolvePromise => {
      const body = JSON.stringify({
        aps: {
          alert,
          sound: 'default',
          category: 'CQUT_APPROVAL',
          'mutable-content': 0,
        },
        eventId,
      })
      const request = connection().request({
        ':method': 'POST',
        ':path': `/3/device/${deviceToken}`,
        'apns-topic': topic,
        'apns-push-type': 'alert',
        'apns-priority': '10',
        authorization: `bearer ${token()}`,
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
        if (status === 410 || status === 400) tokens.delete(deviceToken)
        resolvePromise(false)
      })
      request.end(body)
    })
  }

  return {
    enabled: true,
    tokens,
    register,
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