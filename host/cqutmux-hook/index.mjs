#!/usr/bin/env node
// cqutmux-hook — the host-side gateway for CQUTmux.
//
// Agent hooks POST events here; the iOS app reads them back over the SSH
// session it already has. The listener binds to loopback only: it is reachable
// from the phone through the SSH channel (direct-tcpip), never from the network.
//
//   node index.mjs [--port 24543] [--token <secret>]
//
// Endpoints:
//   GET  /health              liveness + counters
//   GET  /events?since=<id>   events newer than <id> (default: last 100)
//   POST /events              append an event        { source, kind, title, body, data }
//   POST /approve/:id         resolve a pending approval { decision: "allow"|"deny" }

import { createServer } from 'node:http'
import { randomUUID, timingSafeEqual } from 'node:crypto'

const DEFAULT_PORT = 24543
const MAX_EVENTS = 2000

function parseArgs(argv) {
  const args = { port: DEFAULT_PORT, token: process.env.CQUTMUX_TOKEN || '' }
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--port') args.port = Number(argv[++i])
    else if (argv[i] === '--token') args.token = argv[++i]
  }
  return args
}

const args = parseArgs(process.argv.slice(2))

/** @type {Array<object>} */
const events = []
const waiters = new Set()
let nextId = 1
let pendingApprovals = 0

function emit(event) {
  const record = { id: nextId++, at: new Date().toISOString(), ...event }
  events.push(record)
  if (events.length > MAX_EVENTS) events.splice(0, events.length - MAX_EVENTS)
  // Long-polling clients waiting for something new.
  for (const waiter of waiters) waiter(record)
  return record
}

function authorized(req) {
  if (!args.token) return true
  const header = req.headers['authorization'] || ''
  const presented = header.startsWith('Bearer ') ? header.slice(7) : ''
  const a = Buffer.from(presented)
  const b = Buffer.from(args.token)
  return a.length === b.length && timingSafeEqual(a, b)
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = ''
    req.on('data', chunk => {
      body += chunk
      if (body.length > 1 << 20) reject(new Error('body too large'))
    })
    req.on('end', () => resolve(body))
    req.on('error', reject)
  })
}

function json(res, status, payload) {
  const body = JSON.stringify(payload)
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) })
  res.end(body)
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost')

  if (!authorized(req)) return json(res, 401, { error: 'unauthorized' })

  if (req.method === 'GET' && url.pathname === '/health') {
    return json(res, 200, {
      ok: true,
      events: events.length,
      pendingApprovals,
      uptime: Math.round(process.uptime()),
    })
  }

  if (req.method === 'GET' && url.pathname === '/events') {
    const since = Number(url.searchParams.get('since') || 0)
    const wait = url.searchParams.get('wait') === '1'
    const newer = since > 0 ? events.filter(e => e.id > since) : events.slice(-100)

    if (newer.length || !wait) return json(res, 200, { events: newer, lastId: nextId - 1 })

    // Long poll: hold the request until an event arrives or 25s elapse.
    const timer = setTimeout(() => {
      waiters.delete(onEvent)
      json(res, 200, { events: [], lastId: nextId - 1 })
    }, 25_000)
    const onEvent = () => {
      clearTimeout(timer)
      waiters.delete(onEvent)
      json(res, 200, { events: events.filter(e => e.id > since), lastId: nextId - 1 })
    }
    waiters.add(onEvent)

    // Poll the pending-approval counter while we hold the connection open.
    return
  }

  if (req.method === 'POST' && url.pathname === '/events') {
    let parsed
    try {
      parsed = JSON.parse(await readBody(req))
    } catch {
      return json(res, 400, { error: 'invalid JSON' })
    }
    if (!parsed || typeof parsed !== 'object') return json(res, 400, { error: 'expected an object' })

    const kind = parsed.kind === 'approval' ? 'approval' : 'notice'
    if (kind === 'approval') pendingApprovals++
    const record = emit({
      source: parsed.source || 'agent',
      kind,
      title: parsed.title || '',
      body: parsed.body || '',
      data: parsed.data ?? null,
    })
    process.stderr.write(`[hook] #${record.id} ${record.source} ${record.kind} ${record.title}\n`)
    return json(res, 201, record)
  }

  const approve = url.pathname.match(/^\/approve\/(\d+)$/)
  if (req.method === 'POST' && approve) {
    const id = Number(approve[1])
    const target = events.find(e => e.id === id)
    if (!target) return json(res, 404, { error: 'no such event' })
    let decision = 'allow'
    try {
      const body = await readBody(req)
      if (body) decision = JSON.parse(body).decision || decision
    } catch { /* default to allow */ }
    target.decision = decision
    target.resolvedAt = new Date().toISOString()
    if (target.kind === 'approval') pendingApprovals = Math.max(0, pendingApprovals - 1)
    emit({ source: 'app', kind: 'notice', title: `approval ${decision}`, data: { for: id } })
    return json(res, 200, target)
  }

  json(res, 404, { error: 'not found' })
})

server.listen(args.port, '127.0.0.1', () => {
  process.stderr.write(`[hook] listening on 127.0.0.1:${args.port} (token: ${args.token ? 'set' : 'none'})\n`)
})

process.on('SIGINT', () => {
  server.close(() => process.exit(0))
})