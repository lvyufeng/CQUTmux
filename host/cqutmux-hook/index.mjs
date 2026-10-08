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
import { promisify } from 'node:util'
import { execFile } from 'node:child_process'
import { readdir, readFile, stat } from 'node:fs/promises'
import { resolve, relative, isAbsolute, join } from 'node:path'
import { homedir } from 'node:os'

const run = promisify(execFile)

const DEFAULT_PORT = 24543
const MAX_EVENTS = 2000
const MAX_FILE_BYTES = 512 * 1024

function parseArgs(argv) {
  const args = { port: DEFAULT_PORT, token: process.env.CQUTMUX_TOKEN || '', root: homedir() }
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--port') args.port = Number(argv[++i])
    else if (argv[i] === '--token') args.token = argv[++i]
    else if (argv[i] === '--root') args.root = resolve(argv[++i])
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

// Resolve a client-supplied path and refuse anything outside the allowed root.
function safePath(requested) {
  const candidate = isAbsolute(requested || '') ? requested : join(args.root, requested || '')
  const resolved = resolve(candidate)
  const rel = relative(args.root, resolved)
  if (rel.startsWith('..') || isAbsolute(rel)) return null
  return resolved
}

async function listDirectory(dir) {
  const entries = await readdir(dir, { withFileTypes: true })
  const items = entries
    .filter(e => !e.name.startsWith('.'))
    .map(e => ({ name: e.name, dir: e.isDirectory() }))
    .sort((a, b) => (a.dir === b.dir ? a.name.localeCompare(b.name) : a.dir ? -1 : 1))
  return { path: relative(args.root, dir) || '.', entries: items }
}

// Agent rate-limit windows. Claude Code enforces a 5-hour rolling window and a
// 7-day window; the burn pace compares elapsed wall-clock against usage.
const WINDOWS = [
  { label: '5h', ms: 5 * 60 * 60 * 1000, cap: 200 },
  { label: '7d', ms: 7 * 24 * 60 * 60 * 1000, cap: 800 },
]

function humanize(ms) {
  if (ms <= 0) return 'now'
  // Round to whole minutes first, so 59.6m carries into the hour instead of
  // printing "4h 60m".
  const totalMinutes = Math.round(ms / 60000)
  const h = Math.floor(totalMinutes / 60)
  const m = totalMinutes % 60
  return h > 0 ? `${h}h ${m}m` : `${m}m`
}

function usageSnapshot() {
  const now = Date.now()
  const bySource = new Map()
  for (const e of events) {
    if (e.source === 'app') continue
    const t = Date.parse(e.at)
    const list = bySource.get(e.source) || []
    list.push(t)
    bySource.set(e.source, list)
  }

  const entries = []
  for (const [source, times] of bySource) {
    const windows = WINDOWS.map(w => {
      const used = times.filter(t => now - t < w.ms).length
      const percent = Math.min(100, Math.round((used / w.cap) * 1000) / 10)
      // Reset when the oldest event in the window ages out.
      const oldest = times.filter(t => now - t < w.ms).sort((a, b) => a - b)[0]
      return {
        label: w.label,
        percent,
        resetIn: oldest ? humanize(oldest + w.ms - now) : null,
      }
    })
    // Pace: is recent burn faster than the window averages?
    const recent = times.filter(t => now - t < WINDOWS[0].ms).length
    const pace = recent > WINDOWS[0].cap * 0.5
      ? `${source} is burning the 5h window fast`
      : `${source} usage pace is steady`
    entries.push({ source, label: source.replace(/-/g, ' ').replace(/\b\w/g, c => c.toUpperCase()), windows, pace })
  }
  return { generatedAt: new Date().toISOString(), entries }
}

async function gitDiff(cwd, extra = []) {
  try {
    const { stdout: diff } = await run('git', ['diff', '--no-color', ...extra], {
      cwd,
      maxBuffer: 8 * 1024 * 1024,
    })
    const { stdout: status } = await run('git', ['status', '--porcelain'], { cwd })
    const files = status
      .split('\n')
      .filter(Boolean)
      .map(line => ({ status: line.slice(0, 2).trim(), path: line.slice(3) }))
    return { isRepo: true, files, diff }
  } catch {
    return { isRepo: false, files: [], diff: '' }
  }
}

// Enumerates tmux sessions, their windows, and whether a pane is attached, so
// the app can offer a session picker and jump-to-window without a shell round
// trip. Uses a stable tab-separated format rather than tmux's default grid.
async function tmuxSessions() {
  const fmt = [
    '#{session_name}',
    '#{session_windows}',
    '#{session_attached}',
    '#{session_created}',
  ].join('\t')
  let stdout
  try {
    ;({ stdout } = await run('tmux', ['list-sessions', '-F', fmt]))
  } catch (error) {
    // tmux exits non-zero when no server is running; that is not an error here.
    const message = String(error.stderr || error.message || '')
    if (/no server running|no sessions/i.test(message)) return { available: true, sessions: [] }
    return { available: false, error: message.trim() || 'tmux not available', sessions: [] }
  }

  const sessions = []
  for (const line of stdout.split('\n').filter(Boolean)) {
    const [name, windows, attached, created] = line.split('\t')
    if (!name) continue

    const winFmt = [
      '#{window_index}',
      '#{window_name}',
      '#{window_active}',
      '#{window_panes}',
    ].join('\t')
    let winOut = ''
    try {
      ;({ stdout: winOut } = await run('tmux', ['list-windows', '-t', name, '-F', winFmt]))
    } catch {
      // Session may have vanished between the two calls; report what we have.
    }

    sessions.push({
      name,
      windows: Number(windows) || 0,
      attached: Number(attached) > 0,
      createdAt: Number(created) ? new Date(Number(created) * 1000).toISOString() : null,
      windowList: winOut
        .split('\n')
        .filter(Boolean)
        .map(row => {
          const [index, windowName, active, panes] = row.split('\t')
          return {
            index: Number(index),
            name: windowName,
            active: Number(active) > 0,
            panes: Number(panes) || 1,
          }
        }),
    })
  }
  return { available: true, sessions }
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

  if (req.method === 'GET' && url.pathname === '/files') {
    const dir = safePath(url.searchParams.get('path') || '')
    if (!dir) return json(res, 403, { error: 'path outside root' })
    try {
      return json(res, 200, { root: args.root, ...(await listDirectory(dir)) })
    } catch (error) {
      return json(res, 404, { error: String(error.message || error) })
    }
  }

  if (req.method === 'GET' && url.pathname === '/file') {
    const file = safePath(url.searchParams.get('path'))
    if (!file) return json(res, 403, { error: 'path outside root' })
    try {
      const info = await stat(file)
      if (!info.isFile()) return json(res, 400, { error: 'not a file' })
      if (info.size > MAX_FILE_BYTES) return json(res, 413, { error: 'file too large' })
      const content = await readFile(file, 'utf8')
      return json(res, 200, { path: relative(args.root, file), size: info.size, content })
    } catch (error) {
      return json(res, 404, { error: String(error.message || error) })
    }
  }

  if (req.method === 'GET' && url.pathname === '/diff') {
    const dir = safePath(url.searchParams.get('path') || '')
    if (!dir) return json(res, 403, { error: 'path outside root' })
    return json(res, 200, await gitDiff(dir))
  }

  if (req.method === 'GET' && url.pathname === '/usage') {
    return json(res, 200, usageSnapshot())
  }

  if (req.method === 'GET' && url.pathname === '/sessions') {
    return json(res, 200, await tmuxSessions())
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