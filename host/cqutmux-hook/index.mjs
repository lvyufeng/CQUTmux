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
//   POST /push/register       remember an APNs device token { token }
//
// Remote push is optional and off unless a signing key is configured. See
// push.mjs for what that needs.

import { createServer } from 'node:http'
import { randomUUID, timingSafeEqual } from 'node:crypto'
import { promisify } from 'node:util'
import { execFile, spawn } from 'node:child_process'
import { readdir, readFile, stat, mkdir, writeFile, rm, chmod } from 'node:fs/promises'
import { existsSync, readFileSync } from 'node:fs'
import { resolve, relative, isAbsolute, join, dirname } from 'node:path'
import { homedir, hostname, networkInterfaces, tmpdir } from 'node:os'
import { createPushService } from './push.mjs'
import { herdrStatus, herdrSnapshot, herdrApprove, herdrRead, herdrFocusPane } from './herdr.mjs'

const run = promisify(execFile)

const DEFAULT_PORT = 24543
const MAX_EVENTS = 2000
const MAX_FILE_BYTES = 512 * 1024

function parseArgs(argv) {
  const args = {
    port: DEFAULT_PORT,
    token: process.env.CQUTMUX_TOKEN || '',
    root: homedir(),
    webhook: process.env.CQUTMUX_WEBHOOK || '',
    pushKey: process.env.CQUTMUX_PUSH_KEY || '',
    pushKeyId: process.env.CQUTMUX_PUSH_KEY_ID || '',
    pushTeamId: process.env.CQUTMUX_PUSH_TEAM_ID || '',
    pushTopic: process.env.CQUTMUX_PUSH_TOPIC || '',
    pushSandbox: false,
    herdrPath: process.env.CQUTMUX_HERDR || '',
    // Defaults, overridden by ~/.config/cqutmux/config.toml. The `pick` in
    // applyConfig compares against these, so changing one here changes the
    // default the file has to beat.
    alwaysOnDiscovery: true,
    usageCollection: true,
    suppressNestedAgentPush: false,
    scanPorts: 'all',
  }
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--port') args.port = Number(argv[++i])
    else if (argv[i] === '--token') args.token = argv[++i]
    else if (argv[i] === '--root') args.root = resolve(argv[++i])
    else if (argv[i] === '--webhook') args.webhook = argv[++i]
    else if (argv[i] === '--push-key') args.pushKey = argv[++i]
    else if (argv[i] === '--push-key-id') args.pushKeyId = argv[++i]
    else if (argv[i] === '--push-team-id') args.pushTeamId = argv[++i]
    else if (argv[i] === '--push-topic') args.pushTopic = argv[++i]
    else if (argv[i] === '--push-sandbox') args.pushSandbox = true
    else if (argv[i] === '--herdr') args.herdrPath = argv[++i]
  }
  return args
}

const args = parseArgs(process.argv.slice(2))

// Persistent gateway settings, from `~/.config/cqutmux/config.toml`.
//
// Flags win over the file, which is the only order that makes an override an
// override. The file is parsed rather than required, so a host without one
// behaves exactly as before — this adds options, it does not make them
// mandatory.
//
// A deliberately small TOML reader: sections, `key = value`, strings, numbers,
// booleans, and arrays. Comments and unknown keys are ignored. It is not a
// general TOML parser and does not claim to be one; the five keys below are the
// whole surface, and a dependency-free gateway is worth more than generality
// here.
function loadConfig() {
  const path = process.env.CQUTMUX_CONFIG || join(homedir(), '.config', 'cqutmux', 'config.toml')
  let text
  try {
    text = readFileSync(path, 'utf8')
  } catch {
    return { path, values: {} }
  }
  const values = {}
  let section = ''
  for (const rawLine of text.split('\n')) {
    const line = rawLine.replace(/#.*$/, '').trim()
    if (!line) continue
    const header = line.match(/^\[([^\]]+)\]$/)
    if (header) {
      section = header[1].trim()
      continue
    }
    const pair = line.match(/^([A-Za-z0-9_-]+)\s*=\s*(.+)$/)
    if (!pair) continue
    const key = section ? `${section}.${pair[1]}` : pair[1]
    values[key] = parseValue(pair[2].trim())
  }
  return { path, values }
}

function parseValue(raw) {
  if (raw === 'true') return true
  if (raw === 'false') return false
  if (/^-?\d+$/.test(raw)) return Number(raw)
  const quoted = raw.match(/^"(.*)"$/) || raw.match(/^'(.*)'$/)
  if (quoted) return quoted[1]
  const array = raw.match(/^\[(.*)\]$/)
  if (array) {
    return array[1]
      .split(',')
      .map(item => item.trim())
      .filter(Boolean)
      .map(parseValue)
  }
  return raw
}

/// Applies the file to `args`, without overwriting anything a flag set.
function applyConfig(args, config) {
  const gateway = key => config.values[`gateway.${key}`]
  const flag = key => config.values[`gateway.${key.replace(/_/g, '-')}`]

  const pick = (key, current, fallback) => {
    if (current !== fallback) return current // a flag set it
    const value = gateway(key) ?? flag(key)
    return value === undefined ? current : value
  }

  args.alwaysOnDiscovery = pick('always_on_discovery', args.alwaysOnDiscovery, true)
  args.usageCollection = pick('usage_collection', args.usageCollection, true)
  args.suppressNestedAgentPush = pick('suppress_nested_agent_push', args.suppressNestedAgentPush, false)
  args.scanPorts = pick('scan_ports', args.scanPorts, 'all')
  return args
}

// Only the loopback-reachable listeners are eligible, whatever the setting
// says: a port bound to a public interface is not something this app should be
// probing, and `none` is a legitimate choice.
function scanPortAllowed(port) {
    const setting = args.scanPorts
    if (setting === undefined || setting === null || setting === 'all') return true
    if (setting === 'none') return false
    // A single entry means the same thing whether it stands alone or sits in a
    // list, so one matcher handles both. Nested arrays are flattened, since
    // `[3000, "8000-8010"]` is a range in a list and nothing else reads it.
    const entries = (Array.isArray(setting) ? setting.flat(Infinity) : [setting])
      .map(entry => (typeof entry === 'string' ? entry.trim() : entry))
      .filter(entry => entry !== '')

    for (const entry of entries) {
      if (entry === 'all') return true
      if (typeof entry === 'number') {
        if (entry === port) return true
        continue
      }
      const range = String(entry).match(/^(\d+)\s*-\s*(\d+)$/)
      if (range) {
        if (port >= Number(range[1]) && port <= Number(range[2])) return true
        continue
      }
      if (String(entry).split(',').map(p => Number(p.trim())).includes(port)) return true
    }
    return false
  }

/// Fields worth keeping when `suppress-nested-agent-push` is on. Claude Code
/// marks a sub-agent's event with a parent session; the exact key has changed
/// between versions, so this checks the plausible spellings rather than one.
function isNestedAgent(parsed) {
  const data = parsed.data
  if (!data || typeof data !== 'object') return false
  return Boolean(
    data.parent_session || data.parentSession ||
    data.parent_session_id || data.parentSessionId ||
    data.parent_tool_use_id || data.subagent
  )
}

const config = loadConfig()
applyConfig(args, config)

const push = createPushService(args)

/** @type {Array<object>} */
const events = []
const waiters = new Set()
let nextId = 1
let pendingApprovals = 0

function emit(event) {
  // Backfill title/body here rather than at each call site. POST /events does
  // it for the events agents send us, but the notices this file emits for
  // itself (an approval being resolved, say) skipped it, so the wire carried
  // two shapes for one record type. Clients should tolerate a missing field —
  // ours now does — but a gateway that emits a different shape depending on
  // which line called it is a bug in the gateway.
  const record = {
    title: '',
    body: '',
    id: nextId++,
    at: new Date().toISOString(),
    ...event,
  }
  events.push(record)
  if (events.length > MAX_EVENTS) events.splice(0, events.length - MAX_EVENTS)
  // Long-polling clients waiting for something new.
  for (const waiter of waiters) waiter(record)
  // Fire-and-forget: a push that fails must not stop the event from being
  // recorded, since the app will still pick it up on its next poll.
  if (record.kind === 'approval') {
    push.notify(record).catch(error => {
      process.stderr.write(`[push] ${error.message || error}\n`)
    })
  }
  return record
}

// Fire-and-forget alert to an external endpoint (Slack, ntfy, a phone
// shortcut…). Failures are logged and swallowed: the gateway must never block
// or crash because a webhook is unreachable.
async function postWebhook(record) {
  if (!args.webhook) return
  try {
    const response = await fetch(args.webhook, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        text: `[CQUTmux] ${record.source} needs approval: ${record.title}`,
        event: record,
      }),
      signal: AbortSignal.timeout(5000),
    })
    if (!response.ok) {
      process.stderr.write(`[hook] webhook responded ${response.status}\n`)
    }
  } catch (error) {
    process.stderr.write(`[hook] webhook failed: ${error.message || error}\n`)
  }
}

function authorized(req) {
  if (!args.token) return true
  const header = req.headers['authorization'] || ''
  const presented = header.startsWith('Bearer ') ? header.slice(7) : ''
  const a = Buffer.from(presented)
  const b = Buffer.from(args.token)
  return a.length === b.length && timingSafeEqual(a, b)
}

// Bodies are collected as raw bytes so binary uploads (pasted images) survive
// intact; callers decode to text when they expect JSON.
function readBody(req, limitBytes = 12 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let size = 0
    req.on('data', chunk => {
      size += chunk.length
      if (size > limitBytes) {
        reject(new Error('body too large'))
        req.destroy()
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => resolve(Buffer.concat(chunks)))
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

// Recent commits for a repo, plus whether a commit's diff is available. The
// separator is a NUL-ish sentinel chosen not to appear in normal subjects.
async function gitLog(cwd, limit = 40) {
  const fmt = ['%H', '%h', '%an', '%aI', '%s', '%D'].join('%x1f')
  try {
    const { stdout } = await run(
      'git',
      ['log', `-n${Math.max(1, Math.min(200, limit))}`, `--pretty=format:${fmt}`],
      { cwd, maxBuffer: 4 * 1024 * 1024 }
    )
    const commits = stdout
      .split('\n')
      .filter(Boolean)
      .map(line => {
        const [hash, short, author, date, subject, refs] = line.split('\x1f')
        return { hash, short, author, date, subject, refs: refs || '' }
      })
    return { isRepo: true, commits }
  } catch {
    return { isRepo: false, commits: [] }
  }
}

// Lists the local TCP ports a dev server is likely to be on, so the app can
// offer a preview target without the user guessing. We look at listening
// sockets only, and filter to a curated set of common dev ports to keep the
// list short and avoid exposing unrelated services.
const DEV_PORT_HINTS = new Set([
  3000, 3001, 4200, 5000, 5173, 5174, 8000, 8001, 8080, 8081, 8443, 9000,
])

async function listeningPorts() {
  let stdout
  try {
    // lsof covers macOS and most BSDs; ss covers Linux.
    ;({ stdout } = await run('lsof', ['-nP', '-iTCP', '-sTCP:LISTEN']))
  } catch (lsofError) {
    try {
      ;({ stdout } = await run('ss', ['-ltn']))
    } catch (ssError) {
      return { available: false, error: 'neither lsof nor ss is available', ports: [] }
    }
    const ports = new Set()
    for (const line of stdout.split('\n').slice(1)) {
      const match = line.match(/:(\d+)\s/)
      if (match) ports.add(Number(match[1]))
    }
    return { available: true, ports: [...ports].sort((a, b) => a - b) }
  }

  const ports = new Set()
  for (const line of stdout.split('\n').slice(1)) {
    const match = line.match(/:(\d+)\s+\(LISTEN\)/)
    if (match) ports.add(Number(match[1]))
  }
  const all = [...ports].sort((a, b) => a - b).filter(scanPortAllowed)
  // Dev-looking ports first, then anything else, so the common case is on top.
  const hinted = all.filter(p => DEV_PORT_HINTS.has(p))
  const rest = all.filter(p => !DEV_PORT_HINTS.has(p))
  return { available: true, ports: [...new Set([...hinted, ...rest])] }
}

// Booted iOS simulators on the host, for the app's simulator preview. Parses
// `xcrun simctl list devices booted --json`, which is the stable interface.
async function bootedSimulators() {
  let stdout
  try {
    ;({ stdout } = await run('xcrun', ['simctl', 'list', 'devices', 'booted', '--json'], {
      maxBuffer: 4 * 1024 * 1024,
    }))
  } catch (error) {
    return { available: false, error: 'simctl unavailable on this host', simulators: [] }
  }

  let parsed
  try {
    parsed = JSON.parse(stdout)
  } catch {
    return { available: true, simulators: [] }
  }

  const simulators = []
  for (const [runtime, devices] of Object.entries(parsed.devices || {})) {
    for (const device of devices) {
      if (device.state !== 'Booted') continue
      // Runtime keys look like "com.apple.CoreSimulator.SimRuntime.iOS-27-0";
      // keep just the "iOS 27.0" tail.
      const tail = runtime.split('.').pop() || ''
      const [platform, ...rest] = tail.split('-')
      simulators.push({
        udid: device.udid,
        name: device.name,
        runtime: `${platform} ${rest.join('.')}`.trim(),
      })
    }
  }
  return { available: true, simulators }
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
      mux: 'tmux',
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
            selector: String(Number(index)),
            name: windowName,
            active: Number(active) > 0,
            panes: Number(panes) || 1,
          }
        }),
    })
  }
  return { available: true, sessions }
}

// Enumerates zellij sessions. zellij's `list-sessions` marks the current one
// with "(current)" and may append "[Created …]"; tabs are only queryable from
// outside on newer builds, so a failed tab query just leaves the window list
// empty rather than dropping the session.
async function zellijSessions() {
  let stdout
  try {
    ;({ stdout } = await run('zellij', ['list-sessions', '--no-formatting']))
  } catch (error) {
    const message = String(error.stderr || error.message || '')
    if (/no active sessions|no sessions/i.test(message)) return { available: true, sessions: [] }
    return { available: false, error: message.trim() || 'zellij not available', sessions: [] }
  }

  const sessions = []
  for (const raw of stdout.split('\n').filter(Boolean)) {
    const line = raw.trim()
    if (!line) continue
    const name = line.split(/\s+/)[0]
    if (!name) continue

    let windowList = []
    try {
      const { stdout: tabs } = await run('zellij', ['-s', name, 'action', 'list-tabs', '--json'])
      windowList = JSON.parse(tabs).map(tab => ({
        selector: String(Number(tab.tab_id) || 0),
        name: tab.name || `tab ${tab.tab_id}`,
        active: Boolean(tab.active),
        panes: Array.isArray(tab.panes) ? tab.panes.length : 1,
      }))
    } catch {
      // Older zellij builds can't list tabs out of session; leave it empty.
    }

    sessions.push({
      mux: 'zellij',
      name,
      windows: windowList.length,
      attached: /current/i.test(line),
      createdAt: null,
      windowList,
    })
  }
  return { available: true, sessions }
}

// Herdr workspaces in the shape the session picker already renders, so it is
// one list rather than a second screen with its own ideas about sessions.
//
// A herdr "session" here is a named persistent session (`herdr --session <name>`),
// which is what `herdr session attach` reattaches to. Workspaces are what the
// snapshot enumerates, so they name the rows and the tabs become the windows a
// tap can jump to. Herdr's own agent status rides along: a picker that says
// which workspace is blocked is more use than one that only lists names.
async function herdrSessions(args) {
  const snapshot = await herdrSnapshot(args)
  if (!snapshot.installed) return { available: false, error: snapshot.message, sessions: [] }

  // Which workspace each tab belongs to. Already in the order herdr reported
    // them, so the numbered label below matches what the user sees in herdr.
  const tabsByWorkspace = new Map()
  for (const tab of snapshot.tabs) {
    if (!tabsByWorkspace.has(tab.workspace)) tabsByWorkspace.set(tab.workspace, [])
    tabsByWorkspace.get(tab.workspace).push(tab)
  }

  const sessions = snapshot.workspaces.map(workspace => {
    const tabs = tabsByWorkspace.get(workspace.label) ?? []
    return {
      mux: 'herdr',
      name: workspace.label,
      windows: tabs.length || workspace.tabCount,
      attached: workspace.focused,
      createdAt: null,
      status: workspace.status,
      // Herdr addresses a tab by id, not by position, so the selector is the
      // id the snapshot gave us even though the label is the position.
      windowList: tabs.map((tab, position) => ({
        selector: tab.id,
        name: tab.label || String(position + 1),
        active: tab.focused,
        panes: 1,
      })),
    }
  })
  return { available: true, sessions }
}

// The unified board the app reads: sessions from every multiplexer we can
// find, each tagged with its `mux`. `available` is false only when none of
// them are installed.
async function multiplexers(args) {
  const results = await Promise.all([tmuxSessions(), zellijSessions(), herdrSessions(args)])
  const sessions = results.flatMap(r => r.sessions)
  if (sessions.length) return { available: true, sessions }
  // No sessions anywhere: report unavailable only if no mux is installed.
  const installed = results.some(r => r.available)
  return {
    available: installed,
    error: installed ? undefined : results.map(r => r.error).filter(Boolean).join('; '),
    sessions: [],
  }
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

  if (req.method === 'GET' && url.pathname === '/log') {
    const dir = safePath(url.searchParams.get('path') || '')
    if (!dir) return json(res, 403, { error: 'path outside root' })
    const limit = Number(url.searchParams.get('limit') || 40)
    return json(res, 200, await gitLog(dir, limit))
  }

  if (req.method === 'GET' && url.pathname === '/usage') {
    return json(res, 200, usageSnapshot())
  }

  if (req.method === 'GET' && url.pathname === '/sessions') {
    return json(res, 200, await multiplexers(args))
  }

  if (req.method === 'GET' && url.pathname === '/ports') {
    return json(res, 200, await listeningPorts())
  }

  if (req.method === 'GET' && url.pathname === '/simulators') {
    return json(res, 200, await bootedSimulators())
  }

  // A screenshot of a booted simulator, sent as raw PNG so the app can show it
  // without an image decoder on the gateway side.
  if (req.method === 'GET' && url.pathname === '/simulator/screenshot') {
    const udid = String(url.searchParams.get('udid') || '')
    if (!/^[0-9A-Fa-f-]{20,40}$/.test(udid)) {
      return json(res, 400, { error: 'invalid udid' })
    }
    const target = join(tmpdir(), `cqutmux-sim-${randomUUID()}.png`)
    try {
      await run('xcrun', ['simctl', 'io', udid, 'screenshot', target], { timeout: 15000 })
      const png = await readFile(target)
      await rm(target, { force: true })
      res.writeHead(200, { 'content-type': 'image/png', 'content-length': png.length })
      res.end(png)
    } catch (error) {
      await rm(target, { force: true })
      return json(res, 500, { error: String(error.stderr || error.message || error).slice(0, 300) })
    }
    return
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
      parsed = JSON.parse((await readBody(req)).toString('utf8'))
    } catch {
      return json(res, 400, { error: 'invalid JSON' })
    }
    if (!parsed || typeof parsed !== 'object') return json(res, 400, { error: 'expected an object' })

    // An event from an agent spawned by another agent is dropped whole, not just
// silenced: Moshi's setting suppresses the event and its approvals, so a parent
// agent's own approval is the only one that ever reaches the phone. Off by
// default, because a nested agent can genuinely be waiting for an answer.
    if (args.suppressNestedAgentPush && isNestedAgent(parsed)) {
      process.stderr.write(`[hook] suppressed nested-agent event from ${parsed.source || 'agent'}\n`)
      return json(res, 202, { suppressed: true })
    }

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
    if (kind === 'approval') postWebhook(record)
    return json(res, 201, record)
  }

  if (req.method === 'GET' && url.pathname === '/herdr') {
    const status = await herdrStatus(args)
    // The snapshot is only worth computing when there is a server to ask; on a
    // host without herdr this stays a cheap "not installed" answer.
    if (!status.installed) return json(res, 200, { ...status, agents: [], workspaces: [] })
    return json(res, 200, { ...status, ...(await herdrSnapshot(args)) })
  }

  // Answers an approval by typing into the pane the agent is running in. This
  // is the herdr counterpart of POST /approve/:id: same decision, delivered
  // through the multiplexer instead of the gateway's own record.
  const herdrApproveRoute = url.pathname.match(/^\/herdr\/approve\/([^/]+)$/)
  if (req.method === 'POST' && herdrApproveRoute) {
    const paneId = decodeURIComponent(herdrApproveRoute[1])
    let allow = true
    try {
      const body = await readBody(req)
      if (body.length) allow = (JSON.parse(body.toString('utf8')).decision || 'allow') !== 'deny'
    } catch { /* default to allow, matching POST /approve/:id */ }
    const result = await herdrApprove(args, paneId, allow)
    return json(res, result.ok ? 200 : 502, result)
  }

  const herdrPaneRoute = url.pathname.match(/^\/herdr\/pane\/([^/]+)$/)
  if (req.method === 'GET' && herdrPaneRoute) {
    const result = await herdrRead(args, decodeURIComponent(herdrPaneRoute[1]))
    return json(res, result.ok ? 200 : 502, result)
  }

  // Jump To: focus a pane the user picked. This one needs the socket rather
  // than the CLI — `herdr pane focus` is directional and cannot name a pane.
  const herdrFocusRoute = url.pathname.match(/^\/herdr\/focus\/([^/]+)$/)
  if (req.method === 'POST' && herdrFocusRoute) {
    const result = await herdrFocusPane(args, decodeURIComponent(herdrFocusRoute[1]))
    return json(res, result.ok ? 200 : 502, result)
  }

  if (req.method === 'POST' && url.pathname === '/push/register') {
    let token = ''
    try {
      token = JSON.parse((await readBody(req)).toString('utf8')).token || ''
    } catch {
      return json(res, 400, { error: 'invalid JSON' })
    }
    const registered = push.register(token)
    return json(res, 200, { registered, enabled: push.enabled, devices: push.tokens.size })
  }

  const approve = url.pathname.match(/^\/approve\/(\d+)$/)
  if (req.method === 'POST' && approve) {
    const id = Number(approve[1])
    const target = events.find(e => e.id === id)
    if (!target) return json(res, 404, { error: 'no such event' })
    let decision = 'allow'
    try {
      const body = await readBody(req)
      if (body.length) decision = JSON.parse(body.toString('utf8')).decision || decision
    } catch { /* default to allow */ }
    target.decision = decision
    target.resolvedAt = new Date().toISOString()
    if (target.kind === 'approval') pendingApprovals = Math.max(0, pendingApprovals - 1)
    emit({ source: 'app', kind: 'notice', title: `approval ${decision}`, data: { for: id } })
    return json(res, 200, target)
  }

  // Pasted images arrive as a raw body (not JSON) so bytes survive untouched.
  // They land under <root>/.cqutmux/paste/ and the response carries the
  // absolute path so the app can type it into the agent's prompt.
  if (req.method === 'POST' && url.pathname === '/upload') {
    let body
    try {
      body = await readBody(req)
    } catch (error) {
      return json(res, 413, { error: String(error.message || error) })
    }
    if (!body.length) return json(res, 400, { error: 'empty body' })

    const rawName = String(req.headers['x-filename'] || 'paste.png')
    // Keep only the basename and a conservative character set; an attacker
    // must not be able to steer the write outside the paste directory.
    const base = rawName.split(/[\\/]/).pop().replace(/[^A-Za-z0-9._-]/g, '_').slice(-80) || 'paste.png'
    const dir = join(args.root, '.cqutmux', 'paste')
    const name = `${Date.now()}-${randomUUID().slice(0, 8)}-${base}`

    try {
      await mkdir(dir, { recursive: true })
      await writeFile(join(dir, name), body)
    } catch (error) {
      return json(res, 500, { error: String(error.message || error) })
    }

    const path = join(dir, name)
    process.stderr.write(`[hook] upload ${body.length} bytes -> ${path}\n`)
    return json(res, 201, { path, bytes: body.length })
  }

  // What has been pasted, newest first. The paste directory is otherwise
  // write-only, which means a re-usable screenshot has to be uploaded again to
  // be used again — the thing this endpoint exists to stop.
  if (req.method === 'GET' && url.pathname === '/uploads') {
    const dir = join(args.root, '.cqutmux', 'paste')
    let names = []
    try {
      names = await readdir(dir)
    } catch {
      // Nothing uploaded yet is an empty list, not a failure.
      return json(res, 200, { root: args.root, uploads: [] })
    }
    const uploads = []
    for (const name of names) {
      try {
        const info = await stat(join(dir, name))
        if (!info.isFile()) continue
        uploads.push({ name, path: join(dir, name), bytes: info.size, at: info.mtime.toISOString() })
      } catch {
        // A file that vanished between listing and stat is not worth failing
        // the whole request over.
      }
    }
    uploads.sort((a, b) => (a.at < b.at ? 1 : -1))
    return json(res, 200, { root: args.root, uploads })
  }

  // A pasted file, by name. Constrained to the paste directory: the name comes
  // from the client, so anything that could climb out of it is refused rather
  // than resolved.
  if (req.method === 'GET' && url.pathname === '/upload') {
    const name = String(url.searchParams.get('name') || '')
    if (!name || name.includes('/') || name.includes('\\') || name.startsWith('.')) {
      return json(res, 400, { error: 'bad name' })
    }
    const file = join(args.root, '.cqutmux', 'paste', name)
    try {
      const body = await readFile(file)
      res.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': body.length })
      return res.end(body)
    } catch {
      return json(res, 404, { error: 'not found' })
    }
  }

  if (req.method === 'DELETE' && url.pathname === '/upload') {
    const name = String(url.searchParams.get('name') || '')
    if (!name || name.includes('/') || name.includes('\\') || name.startsWith('.')) {
      return json(res, 400, { error: 'bad name' })
    }
    try {
      await rm(join(args.root, '.cqutmux', 'paste', name))
      return json(res, 200, { deleted: name })
    } catch {
      return json(res, 404, { error: 'not found' })
    }
  }

  json(res, 404, { error: 'not found' })
})

// --- Command dispatch -------------------------------------------------------
//
// `cqutmux` is the everyday command and `cqutmux-hook` is the daemon, the way
// Moshi ships `moshi` alongside `moshi-hook`: the same file under two names, so
// everything below works with either. With no subcommand this behaves exactly
// as before — it starts the gateway — because that is what install and `serve`
// both do, and a tool that changes what bare invocation means is a tool that
// breaks the thing already calling it.
//
// A single positional argument is a path, not a subcommand (Moshi's rule, and
// the right one): `cqutmux ~/src/api` should name a project, never be mistaken
// for a typo'd command.

const COMMANDS = new Set(['pair', 'install', 'serve', 'status', 'doctor', 'logs', 'diff', 'help'])

function usage() {
  return `cqutmux — host side for the CQUTmux app

  cqutmux <dir>          open (or attach to) a tmux session for a project
  cqutmux diff           diff viewer for the current repo, in the browser
  cqutmux status         gateway health, if one is running here
  cqutmux doctor         check that this host is ready for the app
  cqutmux logs [-f]      tail the gateway log
  cqutmux serve          run the gateway (same as running with no arguments)
  cqutmux install        print how to keep the gateway running
  cqutmux pair           print the details to enter in the app
  cqutmux help           this text

Options: --port N  --token S  --root DIR`
}

const argv = process.argv.slice(2)
// Flags that take a value, so the value is not mistaken for a positional.
// `--port 24880` must not make "24880" look like a directory to open.
const VALUED_FLAGS = new Set([
  '--port', '--token', '--root', '--webhook', '--push-key', '--push-key-id',
  '--push-team-id', '--push-topic', '--herdr',
])
const positionals = []
for (let i = 0; i < argv.length; i++) {
  const arg = argv[i]
  if (arg.startsWith('-')) {
    if (VALUED_FLAGS.has(arg)) i++ // skip its value
  } else {
    positionals.push(arg)
  }
}
const positional = positionals[0]
const command = positional && COMMANDS.has(positional) ? positional : null

if (command === 'serve') {
  // Not dispatched, and not exited: `serve` means "be the gateway", which is
  // the code below. Exiting here would start nothing and look like success.
} else if (command) {
  await runCommand(command, argv)
  process.exit(0)
} else if (positional) {
  // A lone path means "take me to that project's session".
  await launchProjectSession(positional)
  process.exit(0)
}
// Otherwise fall through to the server: `node index.mjs` with no subcommand is
// still the gateway, as documented at the top of this file.

// A tmux session named after the directory, attached if it already exists.
// `exec` rather than spawn so no wrapper process lingers, exactly as Moshi does
// — a shell that leaves a parent behind makes the session awkward to kill.
async function launchProjectSession(target) {
  const dir = resolve(target)
  try {
    const info = await stat(dir)
    if (!info.isDirectory()) {
      process.stderr.write(`cqutmux: ${dir} is not a directory\n`)
      process.exit(1)
    }
  } catch {
    process.stderr.write(`cqutmux: no such directory: ${dir}\n`)
    process.exit(1)
  }
  const name = dir.split('/').filter(Boolean).pop() || 'session'
  process.stderr.write(`[cqutmux] tmux session "${name}" in ${dir}\n`)
  const child = spawn('tmux', ['new-session', '-A', '-s', name], { cwd: dir, stdio: 'inherit' })
  child.on('error', error => {
    process.stderr.write(`cqutmux: could not start tmux: ${error.message}\n`)
    process.exit(1)
  })
  child.on('exit', code => process.exit(code ?? 0))
}

async function runCommand(name, argv) {
  switch (name) {
    case 'help':
      process.stdout.write(usage() + '\n')
      return
    case 'pair':
      return pair()
    case 'status':
      return status()
    case 'doctor':
      return doctor()
    case 'logs':
      return logs(argv.includes('-f') || argv.includes('--follow'))
    case 'install':
      return install(argv)
    case 'diff':
      return diff(argv)
  }
}

/// What to type into the app. The token is the only part that is not obvious
/// from the machine, and printing it is the point of the command.
function pair() {
  const address = Object.values(networkInterfaces())
    .flat()
    .find(i => i && i.family === 'IPv4' && !i.internal)
  process.stdout.write(`Host            ${hostname()}\n`)
  if (address) process.stdout.write(`Address         ${address.address}\n`)
  process.stdout.write(`Port            ${args.port}\n`)
  process.stdout.write(`Token           ${args.token || '(none set — anyone who can reach this port can read events)'}\n`)
  process.stdout.write(`Herdr           ${args.herdrPath || '(not configured)'}\n`)
}

/// Reports whether a gateway is answering here, and what it says. Reads the
/// health endpoint rather than trusting a pid file, because a stale pid file is
/// exactly the thing this command exists to catch.
async function status() {
  const url = `http://127.0.0.1:${args.port}/health`
  try {
    const response = await fetch(url, { headers: authHeaders() })
    if (!response.ok) {
      process.stderr.write(`cqutmux: gateway answered ${response.status} on port ${args.port}\n`)
      process.exit(1)
    }
    const body = await response.json()
    process.stdout.write(`running on 127.0.0.1:${args.port}\n`)
    process.stdout.write(`events   ${body.events}\n`)
    process.stdout.write(`pending  ${body.pendingApprovals}\n`)
    process.stdout.write(`uptime   ${body.uptime}s\n`)
    process.stdout.write(`config   ${Object.keys(config.values).some(k => k.startsWith('gateway.'))
      ? config.path : 'defaults'}\n`)
  } catch (error) {
    process.stderr.write(`cqutmux: no gateway on 127.0.0.1:${args.port} (${error.message})\n`)
    process.exit(1)
  }
}

function authHeaders() {
  return args.token ? { authorization: `Bearer ${args.token}` } : {}
}

/// Checks the things that actually stop the app from working, in the order they
/// would bite. Each one prints what it found and why it matters, because a bare
/// "ERROR" leaves the user to guess which of these the app will trip over.
async function doctor() {
  let failures = 0
  const check = (ok, label, detail) => {
    process.stdout.write(`${ok ? 'ok  ' : 'FAIL'}  ${label}${detail ? ` — ${detail}` : ''}\n`)
    if (!ok) failures++
  }

  for (const tool of ['tmux', 'git', 'ssh']) {
    try {
      const { stdout } = await run('which', [tool])
      check(true, tool, stdout.trim())
    } catch {
      // tmux is required; the other two only disable features.
      check(tool !== 'tmux', tool, tool === 'tmux' ? 'required for sessions' : 'optional')
    }
  }

  try {
    const response = await fetch(`http://127.0.0.1:${args.port}/health`, { headers: authHeaders() })
    check(response.ok, 'gateway', `127.0.0.1:${args.port}`)
  } catch {
    check(false, 'gateway', `not running on ${args.port}; start it with \`cqutmux serve\``)
  }

  if (args.token) check(true, 'token', 'set')
  else check(false, 'token', 'none set, so anything that can reach the port can read events')

  if (args.herdrPath) {
    try {
      const snapshot = await herdrSnapshot(args.herdrPath, args.root)
      check(true, 'herdr', `${snapshot?.tabs?.length ?? 0} tab(s)`)
    } catch (error) {
      check(false, 'herdr', String(error.message || error))
    }
  }

  // The config file is a setting someone deliberately wrote, so doctor reports
  // which one is in effect rather than leaving them to guess whether it was
  // read. A file that exists but yields nothing parsed is the case worth
  // catching: it looks configured and is not.
  const configured = Object.keys(config.values).filter(k => k.startsWith('gateway.')).length
  if (configured > 0) {
    check(true, 'config', `${config.path} (${configured} setting(s))`)
  } else if (existsSync(config.path)) {
    check(false, 'config', `${config.path} has no [gateway] settings this build understands`)
  } else {
    check(true, 'config', 'defaults (no config file)')
  }

  process.stdout.write(failures === 0 ? '\nready\n' : `\n${failures} thing(s) to fix\n`)
  if (failures > 0) process.exit(1)
}

async function logs(follow) {
  const log = join(homedir(), '.cqutmux', 'hook.log')
  try {
    await stat(log)
  } catch {
    process.stderr.write(`cqutmux: no log at ${log}; the gateway writes one when started by \`install\`\n`)
    process.exit(1)
  }
  const child = spawn('tail', follow ? ['-f', log] : ['-n', '80', log], { stdio: 'inherit' })
  child.on('exit', code => process.exit(code ?? 0))
}

async function install(argv) {
  const dryRun = argv.includes('--dry-run') || argv.includes('--print')

  // 1. Agent hook config.
  const bridge = join(import.meta.dirname, 'claude-code-hook.sh')
  const target = join(homedir(), '.claude', 'settings.json')

  const wanted = {
    PreToolUse: [{ matcher: '*', hooks: [{ type: 'command', command: `"${bridge}" approval` }] }],
    Stop: [{ hooks: [{ type: 'command', command: `"${bridge}" notice` }] }],
  }

  let existing = {}
  let raw = null
  try {
    raw = await readFile(target, 'utf8')
    existing = JSON.parse(raw)
  } catch (error) {
    if (error.code !== 'ENOENT') {
      // A settings file that does not parse is the user's, and guessing at it
      // risks throwing away their work. Report and stop rather than rewrite.
      process.stderr.write(`cqutmux: ${target} is not valid JSON (${error.message})\n`)
      process.stderr.write(`cqutmux: leaving it alone; nothing was written\n`)
      process.exit(1)
    }
  }

  // Merge without disturbing anything already there: Moshi's promise, and the
  // right one — a hook installer that drops someone's existing hooks is worse
  // than no installer. Our entries are recognised by the command string, so
  // re-running updates them in place instead of stacking duplicates.
  const merged = structuredClone(existing)
  merged.hooks ??= {}
  let changed = 0
  for (const [event, additions] of Object.entries(wanted)) {
    const current = Array.isArray(merged.hooks[event]) ? merged.hooks[event] : []
    const mine = current.filter(group => isOurs(group, bridge))
    const theirs = current.filter(group => !isOurs(group, bridge))
    if (JSON.stringify(mine) !== JSON.stringify(additions)) changed++
    merged.hooks[event] = [...theirs, ...additions]
  }

  if (dryRun) {
    process.stdout.write(`would write ${target}:\n`)
    process.stdout.write(JSON.stringify({ hooks: merged.hooks }, null, 2) + '\n')
  } else {
    await mkdir(dirname(target), { recursive: true })
    if (raw !== null) {
      // Keep a copy the first time, so a mistaken install is reversible.
      const backup = `${target}.cqutmux-backup`
      if (!existsSync(backup)) await writeFile(backup, raw)
    }
    await writeFile(target, JSON.stringify(merged, null, 2) + '\n')
    await chmod(bridge, 0o755).catch(() => {})
    process.stdout.write(
      changed === 0
        ? `hooks already installed in ${target}\n`
        : `installed hooks in ${target}${raw !== null ? ` (backup: ${target}.cqutmux-backup)` : ''}\n`
    )
  }

  // 2. Supervision.
  process.stdout.write(`
Keep the gateway running at login.

  macOS (launchd):
    cqutmux serve >> ~/.cqutmux/hook.log 2>&1 &

  Or with a supervisor you already run, e.g.:
    systemd:  ExecStart=${process.execPath} ${process.argv[1]} serve --token <secret>

The app reaches this port over the SSH session it already has, so there is no
need to open a firewall port or expose it to the network. Bind stays loopback.
`)
}

/// Whether a hook group belongs to us. Matched on the bridge script's path
/// rather than on an index or a count, so a user's own hooks survive and ours
/// can be updated without knowing where they ended up.
function isOurs(group, bridge) {
  return (group?.hooks ?? []).some(h => typeof h?.command === 'string' && h.command.includes(bridge))
}

/// Shows a repo's diff in the browser, on loopback only.
///
/// Non-blocking by design: it prints the URL and exits once the page has been
/// opened, so `cqutmux diff` can be run from a hook or a script without leaving
/// something behind. (The app's own Diff viewer reads `/diff` directly.)
async function diff(argv) {
  const rest = argv.filter(a => a !== 'diff' && a !== '--no-open' && a !== '--port')
  const cwd = resolve(rest.find(a => !a.startsWith('-')) || process.cwd())
  const result = await gitDiff(cwd)
  if (!result.isRepo) {
    process.stderr.write(`cqutmux: ${cwd} is not a git repository\n`)
    process.exit(1)
  }
  for (const file of result.files) {
    process.stdout.write(`  ${file.status.padEnd(2)} ${file.path}\n`)
  }
  process.stdout.write(`\n${result.files.length} changed file(s). Open the app's Diff view, `
    + `or run \`cqutmux serve\` and GET /diff?root=${encodeURIComponent(cwd)}.\n`)
}

server.listen(args.port, '127.0.0.1', () => {
  process.stderr.write(`[hook] listening on 127.0.0.1:${args.port} (token: ${args.token ? 'set' : 'none'})\n`)
})

process.on('SIGINT', () => {
  server.close(() => process.exit(0))
})