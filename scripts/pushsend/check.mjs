// What the gateway actually sends to APNs.
//
// The pieces were checked in isolation — the payload builders in
// `liveactivity.mjs`, the decision table — but never that the *request* carries
// them: right path, right push type, right topic suffix for an activity, a
// provider JWT the server would accept, and a body that is the payload and not
// something the transport reshaped. None of that is visible without a signing
// key and a device, and all of it is visible against a local HTTP/2 server.
//
// This does not prove Apple accepts any of it. It proves the gateway sends what
// it means to, which is the half that can be wrong here.

import { createServer } from 'node:http2'
import { generateKeyPairSync } from 'node:crypto'
import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createPushService, providerToken } from '../../host/cqutmux-hook/push.mjs'

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

// MARK: - The provider token

// A real ES256 key, because the JWT has to be signed by something and verifying
// the shape of a signature produced by a broken key would prove nothing.
const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' })
const keyPem = privateKey.export({ type: 'pkcs8', format: 'pem' })

const jwt = providerToken({ key: keyPem, keyId: 'ABC1234567', teamId: 'TEAM123456' })
const [header, claims, signature] = jwt.split('.')
const decode = part => JSON.parse(Buffer.from(part, 'base64url').toString('utf8'))

check(jwt.split('.').length === 3, 'the provider token is a three-part JWT')
check(decode(header).alg === 'ES256', 'signed with ES256, which is what APNs takes')
check(decode(header).kid === 'ABC1234567', 'carrying the key id')
check(decode(claims).iss === 'TEAM123456', 'and the team id as the issuer')
// Seconds, not milliseconds — the same trap as the payload timestamp, in a
// different field.
check(decode(claims).iat < 10_000_000_000, 'issued-at is in seconds')
check(signature && Buffer.from(signature, 'base64url').length === 64,
      'the signature is the raw r||s pair, not DER')

// MARK: - Against a local server

const received = []
const server = createServer()
server.on('stream', (stream, headers) => {
  let body = ''
  stream.on('data', c => { body += c })
  stream.on('end', () => {
    received.push({ headers, body })
    stream.respond({ ':status': 200 })
    stream.end()
  })
})
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
const port = server.address().port

const dir = await mkdtemp(join(tmpdir(), 'cqutmux-push-'))
const keyPath = join(dir, 'key.p8')
await writeFile(keyPath, keyPem)

const push = createPushService({
  pushKey: keyPath,
  pushKeyId: 'ABC1234567',
  pushTeamId: 'TEAM123456',
  pushHost: `http://127.0.0.1:${port}`,
})

try {
  check(push.enabled, 'the service is enabled with all three key parts')

  const device = 'a'.repeat(64)
  const activity = 'b'.repeat(64)
  const start = 'c'.repeat(64)
  push.register(device)
  push.registerActivity(activity)          // per-activity, kind defaults
  push.registerActivity(start, 'start')    // push-to-start

  // An alert push: what an approval has always sent.
  await push.notify({ id: 5, source: 'claude', title: 'Run rm -rf build/' })
  check(received.length === 1, 'an alert push reaches the server')
  let req = received[0]
  check(req.headers[':method'] === 'POST', 'as a POST')
  check(req.headers[':path'] === `/3/device/${device}`, 'to the device token path')
  check(req.headers['apns-push-type'] === 'alert', 'with the alert push type')
  check(req.headers['apns-topic'] === 'app.cqutmux.ios', 'and the plain topic')
  check(String(req.headers.authorization).startsWith('bearer '), 'carrying a bearer token')
  const alertBody = JSON.parse(req.body)
  check(alertBody.aps.alert.title.includes('claude'), 'and the alert names the agent')
  check(alertBody.eventId === 5, "and carries the event id a button press names")

  // A live-activity start. Nothing is running, so this is a start — and a start
  // goes to the *app-level* token, not the activity one. Sending it to the wrong
  // registration is accepted by APNs and attaches to nothing.
  received.length = 0
  await push.notifyActivity({ id: 9, source: 'codex', title: 'Write App.swift', kind: 'approval' },
                            { running: false, nowSeconds: 1_700_000_000 })
  check(received.length === 1, 'a live-activity start reaches the server')
  req = received[0]
  check(req.headers[':path'] === `/3/device/${start}`,
        'addressed to the push-to-start token, not the activity token')
  check(req.headers['apns-push-type'] === 'liveactivity', 'with the liveactivity push type')
  check(req.headers['apns-topic'] === 'app.cqutmux.ios.push-type.liveactivity',
        'and the push-type topic suffix Apple requires')
  const laBody = JSON.parse(req.body)
  check(laBody.aps.event === 'start', 'the body says start')
  check(laBody.aps.timestamp === 1_700_000_000, 'the timestamp is the seconds value given')
  check(laBody.aps['attributes-type'] === 'AgentActivityAttributes',
        'and the attributes type the widget decodes')
  check(laBody.aps['content-state'].phase === 'approval_required',
        'and the content-state the widget renders')

  // An update with an activity running goes to the *other* token.
  received.length = 0
  await push.notifyActivity({ id: 9, source: 'codex', title: 'Edit', kind: 'tool' },
                            { running: true, nowSeconds: 1_700_000_000 })
  check(received.length === 1, 'an update reaches the server')
  check(received[0].headers[':path'] === `/3/device/${activity}`,
        'addressed to the activity token, not the push-to-start one')
  const upd = JSON.parse(received[0].body)
  check(upd.aps.event === 'update', 'and says update')
  check(upd.aps['attributes-type'] === undefined, 'an update carries no attributes')

  // Nothing to do is no request at all — the in-app poll covers those cases, and
  // sending one would be claiming a Lock Screen entry that never appeared.
  received.length = 0
  await push.notifyActivity({ id: 3, source: 'claude', kind: 'who-knows' }, { running: true })
  check(received.length === 0, 'an event with no phase sends nothing')

  // Unregistering the activity token stops updates; the push-to-start token is
  // still there, so a start would still go out.
  push.unregisterActivity(activity)
  received.length = 0
  await push.notifyActivity({ id: 9, source: 'codex', title: 'Edit', kind: 'tool' },
                            { running: true, nowSeconds: 1_700_000_000 })
  check(received.length === 0, 'an update after the activity token was removed sends nothing')

  // A dead token is swept: 410 means uninstalled or rotated, and keeping it is
  // pushing into the void forever.
  server.removeAllListeners('stream')
  server.on('stream', (stream, headers) => {
    stream.respond({ ':status': 410 })
    stream.end()
  })
  push.register(device)
  await push.notify({ id: 7, source: 'claude', title: 'x' })
  check(!push.tokens.has(device), 'a 410 response removes the device token')

  // The sender holds an HTTP/2 session open. Without closing it the process
  // never ends — the check would print its verdict and then hang, which is how
  // a CI run reports "passed" while never returning.
  check(typeof push.close === 'function', 'the service exposes a way to close its connection')
} finally {
  push.close()
  server.close()
  await rm(dir, { recursive: true, force: true })
}

if (failures > 0) {
  console.log(`\nPUSHSEND_FAIL  (${failures} of ${checks} failed)`)
  process.exit(1)
}
console.log(`\nPUSHSEND_PASS  (${checks} checks)`)
