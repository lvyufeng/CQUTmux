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
//   GET  /simulators          booted iOS simulators on this host
//   GET  /simulator/screenshot?udid=…   one PNG frame
//   POST /simulator/touch     tap/drag/pinch a booted simulator { udid, type, x, y, … }
//
// Remote push is optional and off unless a signing key is configured. See
// push.mjs for what that needs.

import { createServer } from 'node:http'
import { randomUUID, timingSafeEqual } from 'node:crypto'
import { promisify } from 'node:util'
import { execFile, spawn } from 'node:child_process'
import { readdir, readFile, stat, mkdir, writeFile, appendFile, rm, chmod } from 'node:fs/promises'
import { existsSync, readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs'
import { resolve, relative, isAbsolute, join, dirname } from 'node:path'
import { homedir, hostname, networkInterfaces, tmpdir, userInfo } from 'node:os'
import { createPushService } from './push.mjs'
import { herdrStatus, herdrSnapshot, herdrApprove, herdrRead, herdrFocusPane, herdrZoomPane } from './herdr.mjs'
import { readTranscript } from './transcript.mjs'
import { recentDirectories } from './recent.mjs'
import { commandHistory } from './history.mjs'
import { terminal as qrTerminal } from './qr.mjs'
import { sendGesture, stopAllSessions, touchHelperAvailable } from './simtouch.mjs'

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
    user: process.env.CQUTMUX_USER || userInfo().username,
    host: process.env.CQUTMUX_HOST || '',
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
    else if (argv[i] === '--user') args.user = argv[++i]
    else if (argv[i] === '--host') args.host = argv[++i]
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
  //
  // `data` is in the same list for a subtler reason: it was stored on the way
  // in but not read back out, so anything an agent put there — which agent
  // spawned this event, which teammate sent it — reached /events as nothing.
  // The one place that reads `data` is nested-agent suppression, and that runs
  // on the *request* body before this, so the field was silently dropped for
  // every consumer downstream of here.
  const record = {
    title: '',
    body: '',
    data: null,
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

/// Puts text on the host's clipboard, best effort.
///
/// Three tools, because there is no one of them everywhere: `pbcopy` on macOS,
/// `wl-copy` on Wayland, `xclip` on X11. Which one is present is not something
/// to ask about at startup — a host may gain or lose a display server under us
/// — so each is tried in turn and the first that works wins.
///
/// Returns a description of what happened rather than throwing: the upload has
/// already succeeded by the time this runs, and a missing clipboard tool is the
/// normal state of a headless server.
async function copyToHostClipboard(text, enabled = true) {
  if (!enabled) return { copied: false, reason: 'disabled' }

  // `-selection clipboard` rather than X11's PRIMARY: PRIMARY is the
  // select-to-paste buffer, and a pasted path should land where Ctrl-V reads.
  const tools = [
    ['pbcopy', []],
    ['wl-copy', []],
    ['xclip', ['-selection', 'clipboard']],
  ]
  for (const [tool, args] of tools) {
    try {
      await new Promise((resolve, reject) => {
        const child = spawn(tool, args)
        child.on('error', reject)
        child.on('close', code => (code === 0 ? resolve() : reject(new Error(`${tool} exited ${code}`))))
        child.stdin.on('error', reject)
        child.stdin.end(text)
      })
      return { copied: true, tool }
    } catch {
      // Try the next one.
    }
  }
  return { copied: false, reason: 'no clipboard tool (pbcopy, wl-copy or xclip)' }
}

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
      // Whether the simulator touch helper can be built. The app uses this to
      // say so before a gesture silently does nothing, rather than after.
      simTouch: touchHelperAvailable(),
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
    // `?file=` narrows the diff to one path, which is what the app asks for
    // when you open a changed file: the full-repo diff is still in the payload
    // for the list, and re-sending it to show one file would be a megabyte of
    // text the phone already has.
    const file = url.searchParams.get('file')
    if (file) {
      // Refused rather than joined when absolute: `join` would quietly re-root
      // `/etc/passwd` under the repo, so the check would *pass* and git would
      // then be handed a path outside the tree — answering 200 with an empty
      // diff, which looks like a clean file rather than a refused request.
      // A path that escapes upward is refused the same way.
      if (isAbsolute(file) || !safePath(join(dir, file))) {
        return json(res, 403, { error: 'file outside root' })
      }
      // `--` so a filename that looks like a flag or a revision is a path.
      return json(res, 200, await gitDiff(dir, ['--', file]))
    }
    return json(res, 200, await gitDiff(dir))
  }

  if (req.method === 'GET' && url.pathname === '/log') {
    const dir = safePath(url.searchParams.get('path') || '')
    if (!dir) return json(res, 403, { error: 'path outside root' })
    const limit = Number(url.searchParams.get('limit') || 40)
    return json(res, 200, await gitLog(dir, limit))
  }

  if (req.method === 'GET' && url.pathname === '/transcript') {
    const dir = safePath(url.searchParams.get('path') || '')
    if (!dir) return json(res, 403, { error: 'path outside root' })
    const limit = Math.min(1000, Number(url.searchParams.get('limit') || 200))
    try {
      return json(res, 200, await readTranscript(dir, limit))
    } catch (error) {
      // A transcript we cannot read is "no chat yet", not a failed request:
      // the app should fall back to the terminal rather than show an error for
      // a session that may simply not have started.
      return json(res, 200, { found: false, messages: [], error: String(error.message || error) })
    }
  }

  if (req.method === 'GET' && url.pathname === '/usage') {
    // `usage-collection off` was parsed from the config file and then never
    // read, so the setting did nothing at all. It now stops this endpoint
    // serving anything: this gateway only ever computes usage when asked, so
    // the flag cannot mean "do not poll in the background" — there is no
    // background — and the honest reading of it is "do not collect this".
    // `enabled: false` is returned rather than a 403 so the app can say why the
    // board is empty instead of showing an error for a choice the user made.
    if (args.usageCollection === false) {
      return json(res, 200, { enabled: false, generatedAt: new Date().toISOString(), entries: [] })
    }
    return json(res, 200, { enabled: true, ...usageSnapshot() })
  }

  if (req.method === 'GET' && url.pathname === '/sessions') {
    return json(res, 200, await multiplexers(args))
  }

  if (req.method === 'GET' && url.pathname === '/ports') {
    // `always-on-discovery off` likewise did nothing. As with usage there is no
    // background scan here to stop, so the flag disables discovery itself.
    if (args.alwaysOnDiscovery === false) {
      return json(res, 200, { enabled: false, available: true, ports: [] })
    }
    return json(res, 200, { enabled: true, ...(await listeningPorts()) })
  }

  if (req.method === 'GET' && url.pathname === '/history') {
    // Deliberately *not* gated on `always-on-discovery`: that flag is about
    // probing the host unasked, and this is the user asking for their own
    // shell's history on a screen they just opened.
    try {
      const limit = Math.min(200, Number(url.searchParams.get('limit') || 200))
      return json(res, 200, { available: true, ...(await commandHistory({ limit })) })
    } catch (error) {
      // A history file that cannot be read is an empty list, not a failed
      // request: the screen it feeds is a picker, and the fallback — typing
      // the command — is always available.
      return json(res, 200, {
        available: false, commands: [], error: String(error?.message || error),
      })
    }
  }

  if (req.method === 'GET' && url.pathname === '/recent-directories') {
    // Gated on the same flag as the port scan: both are "look at the host
    // unasked", and a user who turned that off meant it for the whole class of
    // probes rather than for the one screen they happened to be looking at.
    if (args.alwaysOnDiscovery === false) {
      return json(res, 200, { enabled: false, available: true, directories: [] })
    }
    // Best-effort and silent, like the port probe: a host with no agents
    // installed produces an empty list, not an error the app has to explain.
    try {
      return json(res, 200, { enabled: true, available: true, ...(await recentDirectories()) })
    } catch (error) {
      return json(res, 200, {
        enabled: true, available: true, directories: [],
        error: String(error?.message || error),
      })
    }
  }

  if (req.method === 'GET' && url.pathname === '/simulators') {
    return json(res, 200, await bootedSimulators())
  }

  // A touch, drag or pinch sent to a booted simulator, so the app can drive one
  // live rather than only watch it. Coordinates are normalised 0..1 so the
  // phone does not have to know the device's pixel size.
  //
  // Named /simulator/touch rather than a sibling of /simulator/screenshot to
  // match it: both act on one device, and the prefix keeps them together.
  if (req.method === 'POST' && url.pathname === '/simulator/touch') {
    let body
    try {
      body = JSON.parse(await readBody(req) || '{}')
    } catch (error) {
      return json(res, 400, { error: 'invalid JSON body' })
    }
    const udid = String(body.udid || '')
    if (!/^[0-9A-Fa-f-]{20,40}$/.test(udid)) {
      return json(res, 400, { error: 'invalid udid' })
    }
    // Only the gestures the app can send, and each field checked here rather
    // than trusting the client: the helper parses numbers out of this and a
    // NaN would be injected as a touch at an undefined point.
    const point = value => {
      const n = Number(value)
      return Number.isFinite(n) ? Math.min(1, Math.max(0, n)) : null
    }
    const gesture = { type: String(body.type || '') }
    const clamped = {
      x: point(body.x ?? 0.5),
      y: point(body.y ?? 0.5),
      x2: point(body.x2 ?? 0.5),
      y2: point(body.y2 ?? 0.5),
      edge: Number.isFinite(Number(body.edge)) ? Number(body.edge) : 0,
      ms: Number.isFinite(Number(body.ms)) ? Math.min(5000, Math.max(50, Number(body.ms))) : 300,
      start: Number.isFinite(Number(body.start)) ? Number(body.start) : 0.6,
      scale: Number.isFinite(Number(body.scale)) ? Number(body.scale) : 2,
    }
    if (clamped.x === null || clamped.y === null) {
      return json(res, 400, { error: 'x and y must be numbers in 0..1' })
    }
    if (!['tap', 'down', 'move', 'up', 'swipe', 'pinch'].includes(gesture.type)) {
      return json(res, 400, { error: 'unknown gesture type' })
    }
    try {
      return json(res, 200, await sendGesture(udid, { ...gesture, ...clamped }))
    } catch (error) {
      // 502: the gateway is fine, the helper it drives is not. The message is
      // the fix (build the helper, boot a simulator, install Xcode), so it is
      // passed through rather than replaced with a generic failure.
      return json(res, 502, { error: String(error.message || error).slice(0, 400) })
    }
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

  // Pinch on the terminal: full-screen herdr's focused pane, or restore the
  // layout. The body carries the direction, so the same gesture never means
  // different things on alternate pinches.
  if (req.method === 'POST' && url.pathname === '/herdr/zoom') {
    let zoomed = true
    try {
      const body = await readBody(req)
      if (body.length) zoomed = JSON.parse(body.toString('utf8')).zoomed !== false
    } catch { /* default to zooming in, which is what "pinch out" means */ }
    const result = await herdrZoomPane(args, zoomed)
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
    let answer = ''
    try {
      const body = await readBody(req)
      if (body.length) {
        const parsed = JSON.parse(body.toString('utf8'))
        decision = parsed.decision || decision
        // A question with options is answered by choosing one, not by
        // allowing or denying. The choice rides alongside `decision` rather
        // than replacing it so a client that does not know about options —
        // an older build, a webhook consumer — still reads a resolution it
        // understands.
        if (typeof parsed.answer === 'string') answer = parsed.answer
      }
    } catch { /* default to allow */ }
    target.decision = decision
    if (answer) target.answer = answer
    target.resolvedAt = new Date().toISOString()
    if (target.kind === 'approval') pendingApprovals = Math.max(0, pendingApprovals - 1)
    // Carry the resolved event's session along with its id. The id is enough to
    // tie the notice to what it resolves, but the session is what a board
    // merges rows on, and a client that only looks at sessions would otherwise
    // open a second row for the answer.
    emit({
      source: 'app',
      kind: 'notice',
      title: `approval ${decision}`,
      data: { for: id, session: target.data?.session ?? null, decision, answer: answer || null },
    })
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

    // Put the path on the host's clipboard, so the file can be pasted into a
    // running program without retyping it — the app types it into the agent
    // prompt, which is not what you want when the target is a `vim` already
    // open in a pane. Best effort: a host with no clipboard tool is common
    // (a bare server, a container), and the upload itself has already
    // succeeded, so a failure here must not turn into a failed upload.
    const clipboard = await copyToHostClipboard(path, req.headers['x-clipboard'] !== 'off')
    return json(res, 201, { path, bytes: body.length, clipboard })
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

/// The version. Kept here rather than read from a package.json, because there
/// is no package.json — this host ships as loose .mjs files — and inventing a
/// `0.0.0` fallback would make `cqutmux version` print a number that is not the
/// app's. `scripts/cli-check.sh` asserts this string matches `project.yml`'s
/// MARKETING_VERSION, so the two cannot drift apart unnoticed.
const VERSION = '0.1.0'

/// `cqutmux set` — read, or write one key, of the config file.
///
/// Writes the file rather than a flag so the setting persists the way the
/// parser expects to find it. Unknown keys are refused: the config file is
/// parsed by a small hand-rolled reader, and a typo'd key that silently did
/// nothing would be the exact failure this command exists to make visible.
const SETTABLE = [
  'always_on_discovery', 'usage_collection', 'suppress_nested_agent_push', 'scan_ports',
]

const COMMANDS = new Set([
  'pair', 'install', 'uninstall', 'serve', 'status', 'doctor', 'logs', 'diff',
  'set', 'usage', 'version', 'update', 'help',
])

function usage() {
  return `cqutmux — host side for the CQUTmux app

  cqutmux <dir>          open (or attach to) a tmux session for a project
  cqutmux diff           diff viewer for the current repo, in the browser
  cqutmux status         gateway health, if one is running here
  cqutmux doctor         check that this host is ready for the app
  cqutmux logs [-f]      tail the gateway log
  cqutmux serve          run the gateway (same as running with no arguments)
  cqutmux install        print how to keep the gateway running
  cqutmux uninstall      remove the hooks this tool installed
  cqutmux set            show the config settings and their file, or change one
  cqutmux set --first-run  reopen the first-run prompt on the next install
  cqutmux update         re-wire the hooks and report the version
  cqutmux usage          agent rate-limit windows, as the app shows them
  cqutmux pair           set up a phone: print a link and its QR code
  cqutmux version        print the version
  cqutmux help           this text

Options: --port N  --token S  --root DIR  --user U  --host H
         --base-url URL  talk to a forwarded gateway elsewhere
         --verbose       show the requests, on stderr`
}

const argv = process.argv.slice(2)
// Flags that take a value, so the value is not mistaken for a positional.
// `--port 24880` must not make "24880" look like a directory to open.
const VALUED_FLAGS = new Set([
  '--port', '--token', '--root', '--webhook', '--push-key', '--push-key-id',
  '--push-team-id', '--push-topic', '--herdr', '--user', '--host',
  // One-shot overrides for the commands that talk to a gateway: a different
  // machine's port-forward, or the same command with its reasoning shown.
  '--base-url',
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
  // Honour an exit code a command set. `status` and `usage` signal "no
  // gateway" that way, and forcing 0 here would make `cqutmux status` succeed
  // in a script that just found no gateway.
  process.exit(process.exitCode ?? 0)
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
      return status(argv.includes('--json'))
    case 'doctor':
      return doctor(argv.includes('--yes') || argv.includes('-y'))
    case 'logs':
      return logs(argv.includes('-f') || argv.includes('--follow'))
    case 'install':
      return install(argv)
    case 'uninstall':
      return uninstall()
    case 'diff':
      return diff(argv)
    case 'set':
      return setCommand(positionals.slice(1))
    case 'usage':
      return usageCommand(argv.includes('--sync'))
    case 'version':
      return versionCommand()
    case 'update':
      return update(argv)
  }
}

/// `cqutmux version`. The app and the gateway are versioned together, so this
/// is the same number the app's Support screen shows.
function versionCommand() {
  process.stdout.write(`cqutmux ${VERSION}\n`)
}

function setCommand(rest) {
  const config = loadConfig()
  if (rest.length === 0) {
    // The path is the answer to "which file is in effect", and it goes to
    // stdout because it is the command's output, not a diagnostic.
    process.stdout.write(`${config.path}\n`)
    note(`${SETTABLE.length} setting(s); unset means the built-in default`)
    for (const key of SETTABLE) {
      const value = config.values[`gateway.${key}`]
      process.stdout.write(`  ${key} = ${value === undefined ? '(unset)' : JSON.stringify(value)}\n`)
    }
    return
  }
  const [key, raw] = rest

  // `set --first-run` clears the marker that says the first-run prompt has been
  // seen, so the next launch shows it again. It is a *reset*, not a setting,
  // which is why it is handled before the key lookup — otherwise it would be
  // reported as an unknown setting, which is what it looks like from the
  // outside and is not a helpful answer.
  if (key === '--first-run' || key === 'first-run') {
    const marker = join(homedir(), '.cqutmux', 'installed')
    try {
      if (existsSync(marker)) rmSync(marker, { force: true })
      process.stdout.write('first-run prompt will be shown again on the next install\n')
    } catch (error) {
      process.stderr.write(`cqutmux: could not clear ${marker}: ${error.message}\n`)
      process.exitCode = 1
    }
    return
  }

  const name = key.replace(/-/g, '_')
  if (!SETTABLE.includes(name)) {
    process.stderr.write(`cqutmux: unknown setting "${key}". Known: ${SETTABLE.join(', ')}\n`)
    process.exitCode = 1
    return
  }
  if (raw === undefined) {
    const value = config.values[`gateway.${name}`]
    process.stdout.write(`${value === undefined ? '(unset)' : JSON.stringify(value)}\n`)
    return
  }
  const value = parseSetting(raw)
  writeConfigValue(config, name, value)
  process.stdout.write(`[gateway] ${name} = ${JSON.stringify(value)}\n`)
}

/// Turns a command-line word into the value the config reader would produce.
///
/// The reader turns `true`/`false` into booleans and everything else into a
/// string, and the gateway branches on `=== false` for these keys — so writing
/// the quoted string `"off"` for `set usage-collection off` would persist a
/// value that reads back as a truthy string and turns the setting *on*. Because
/// of that, `on`/`off` are accepted here as spellings of the booleans, which is
/// what a person types for a switch.
function parseSetting(raw) {
  const word = raw.trim()
  if (word === 'true' || word === 'on' || word === 'yes') return true
  if (word === 'false' || word === 'off' || word === 'no') return false
  return parseValue(word)
}

/// Rewrites one `[gateway]` key, leaving every other line — comments included —
/// untouched. A hand-rolled reader deserves a hand-rolled writer: rebuilding the
/// file from the parsed object would silently drop the comments someone put
/// there to explain their own settings.
///
/// The one comment that cannot survive is a trailing one on the line being
/// changed, since the whole line is replaced. That is the right trade: a
/// comment that says "keep me on" next to a value that now says `false` is
/// worse than no comment at all.
function writeConfigValue(config, key, value) {
  let lines = []
  try {
    lines = readFileSync(config.path, 'utf8').split('\n')
  } catch {
    lines = []
  }
  const rendered = typeof value === 'string' ? `"${value}"` : JSON.stringify(value)
  const assignment = `${key} = ${rendered}`

  let sectionStart = -1
  let sectionEnd = lines.length
  let replaced = false
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].replace(/#.*$/, '').trim()
    const header = line.match(/^\[([^\]]+)\]$/)
    if (header) {
      if (sectionStart !== -1) { sectionEnd = i; break }
      if (header[1].trim() === 'gateway') sectionStart = i
      continue
    }
    if (sectionStart !== -1 && i > sectionStart) {
      const pair = line.match(/^([A-Za-z0-9_-]+)\s*=/)
      if (pair && pair[1] === key) {
        lines[i] = assignment
        replaced = true
      }
    }
  }

  if (!replaced) {
    if (sectionStart === -1) {
      // No [gateway] section at all: append one, keeping any trailing newline
      // from doubling up.
      while (lines.length && lines[lines.length - 1].trim() === '') lines.pop()
      if (lines.length) lines.push('')
      lines.push('[gateway]', assignment, '')
    } else {
      // Insert after the section's last real line, not at its index boundary:
      // appending at `sectionEnd` would land *after* a trailing blank line that
      // belongs to the section, leaving the new key visually detached from the
      // ones above it. Walk back over blanks to find where the section's
      // content actually stops.
      let at = sectionEnd
      while (at > sectionStart + 1 && lines[at - 1].trim() === '') at--
      lines.splice(at, 0, assignment)
    }
  } else {
    // An edit that replaced a line has consumed no trailing newline; an edit
    // that appended one has one to spare. Normalising to a single trailing
    // newline keeps repeated `set` calls from growing the file a blank line at
    // a time.
    while (lines.length && lines[lines.length - 1].trim() === '') lines.pop()
    lines.push('')
  }

  mkdirSync(dirname(config.path), { recursive: true })
  writeFileSync(config.path, lines.join('\n'))
}

/// `cqutmux usage` — the same windows the app's Usages board shows.
///
/// Fetched from a running gateway rather than computed here, because the event
/// log lives in the daemon's memory: a fresh process has seen no events, so a
/// standalone computation would print an empty board and look like a broken
/// feature. This reaches the gateway over the same loopback endpoint the app
/// does, which also means it sees exactly what the app sees.
async function usageCommand(sync = false) {
  const url = `${baseUrl()}/usage`
  note(`GET ${url}${sync ? '?sync=1' : ''}`)
  let body
  try {
    const response = await fetch(url, { headers: authHeaders() })
    if (!response.ok) {
      process.stderr.write(`cqutmux: gateway answered ${response.status} at ${baseUrl()}\n`)
      process.exit(1)
    }
    body = await response.json()
  } catch (error) {
    process.stderr.write(
      `cqutmux: no gateway at ${baseUrl()} (${error.message})\n` +
      `Usage is counted from events the gateway has seen, so it needs one running.\n`
    )
    process.exit(1)
  }
  // `--sync` asks the gateway to refresh from the providers first. The counters
  // otherwise come from what the hooks reported, which is only as fresh as the
  // last agent event — so a script that wants the current numbers has to say so
  // rather than being handed whatever the daemon happens to hold.
  if (sync && body.enabled !== false) {
    try {
      const refreshed = await fetch(`${url}?sync=1`, { headers: authHeaders() })
      if (refreshed.ok) body = await refreshed.json()
    } catch {
      // Falls through to what was already fetched: a failed refresh is not
      // worth failing the command over when a readable board is in hand.
    }
  }
  if (body.enabled === false) {
    process.stdout.write('usage collection is off (cqutmux set usage-collection on)\n')
    return
  }
  if (!body.entries || !body.entries.length) {
    process.stdout.write('no agent events recorded yet\n')
    return
  }
  for (const entry of body.entries) {
    process.stdout.write(`${entry.label}\n`)
    for (const window of entry.windows) {
      const reset = window.resetIn ? `, resets in ${window.resetIn}` : ''
      process.stdout.write(`  ${window.label.padEnd(3)} ${String(window.percent).padStart(5)}%${reset}\n`)
    }
    process.stdout.write(`  ${entry.pace}\n`)
  }
}

/// `cqutmux uninstall` — remove the hooks `install` wrote.
///
/// Only the entries this tool added, matched by the bridge script path, so a
/// hand-written hook of the user's own in the same file is left alone. The
/// backup `install` made is deliberately not restored: it would also undo any
/// hook the user added after installing, which is a bigger surprise than
/// leaving a `.cqutmux-backup` file behind for them to inspect.
async function uninstall() {
  let total = 0
  for (const agent of agentHooks()) {
    try {
      total += await uninstallAgent(agent)
    } catch (error) {
      process.stderr.write(`cqutmux: could not clean ${agent.label}: ${error.message}\n`)
    }
  }
  if (!total) {
    process.stdout.write('nothing to uninstall: no cqutmux hooks found\n')
    return
  }
  process.stdout.write(`removed ${total} hook entr${total === 1 ? 'y' : 'ies'}\n`)
}

/// Removes our hooks from one agent, leaving everything else as it was.
///
/// Matched on the bridge path rather than on an index or a count, which is what
/// lets a user's own hooks in the same file survive — the promise `install`
/// makes and the only one that makes it safe to run.
async function uninstallAgent(agent) {
  if (agent.format === 'kimi-toml') {
    let text
    try {
      text = await readFile(agent.path, 'utf8')
    } catch {
      return 0
    }
    if (!text.includes(agent.bridge)) return 0
    const blocks = text.split(/(?=^\[\[hooks\]\])/m)
    const kept = blocks.filter(block => !block.includes(agent.bridge))
    const removed = blocks.length - kept.length
    await writeFile(agent.path, kept.join('').trimEnd() + '\n')
    process.stdout.write(`removed ${removed} hook(s) from ${agent.path}\n`)
    return removed
  }

  let settings
  try {
    settings = JSON.parse(await readFile(agent.path, 'utf8'))
  } catch {
    return 0
  }

  let removed = 0
  if (agent.format === 'cursor') {
    const hooks = settings.hooks ?? {}
    for (const [event, entries] of Object.entries(hooks)) {
      if (!Array.isArray(entries)) continue
      const kept = entries.filter(entry => !agent.ours(entry))
      removed += entries.length - kept.length
      if (kept.length) hooks[event] = kept
      else delete hooks[event]
    }
  } else if (agent.format === 'antigravity') {
    if (settings.cqutmux) {
      removed = 1
      delete settings.cqutmux
    }
  } else {
    const hooks = settings.hooks ?? {}
    for (const [event, entries] of Object.entries(hooks)) {
      if (!Array.isArray(entries)) continue
      const kept = entries.filter(entry => !agent.ours(entry))
      removed += entries.length - kept.length
      if (kept.length) hooks[event] = kept
      else delete hooks[event]
    }
  }

  if (!removed) return 0
  await writeFile(agent.path, JSON.stringify(settings, null, 2) + '\n')
  process.stdout.write(`removed ${removed} hook(s) from ${agent.path}\n`)
  return removed
}

/// The address the phone should dial: the first non-loopback IPv4, or whatever
/// `--host` says. `--host` exists for the machines where the first non-loopback
/// address is not the one on the network the phone is joined to (a Docker or
/// VPN interface, a second NIC), which is otherwise an unfixable wrong answer.
function pairAddress() {
  if (args.host) return args.host
  const found = Object.values(networkInterfaces())
    .flat()
    .find(i => i && i.family === 'IPv4' && !i.internal)
  return found ? found.address : '127.0.0.1'
}

function pairKeyPath() {
  // A dedicated file, not `id_ed25519`: that key is the user's own, reused by
  // every other tool on the machine, and pairing hands the private half to a
  // phone. Overwriting it would break their logins everywhere; reading it would
  // mean the phone holds the key to everything.
  return join(homedir(), '.ssh', 'cqutmux_ed25519')
}

/// Percent-encodes a value for the link. Escapes the same delimiter set the
/// app's `Pairing.escape` does — the two ends have to agree on this or a token
/// containing `&` arrives truncated at the phone.
function pairEscape(value) {
  return encodeURIComponent(value).replace(/[!'()*]/g, c =>
    `%${c.charCodeAt(0).toString(16).toUpperCase().padStart(2, '0')}`)
}

/// The private key's 32-byte seed out of an unencrypted `openssh-key-v1` file.
///
/// The same extraction the app does, and for the same reason: the seed is what
/// the app stores, so handing over the file itself would mean the phone parsing
/// a format on a path where a mistake costs a connection.
function privateKeySeed(pem) {
  const body = pem.split('\n').filter(line => !line.startsWith('-----')).join('')
  const blob = Buffer.from(body, 'base64')
  const magic = Buffer.from('openssh-key-v1\0', 'utf8')
  if (!blob.subarray(0, magic.length).equals(magic)) {
    throw new Error('not an openssh-key-v1 private key')
  }
  let offset = magic.length
  const readString = () => {
    const length = blob.readUInt32BE(offset)
    offset += 4
    const value = blob.subarray(offset, offset + length)
    offset += length
    return value
  }
  const cipher = readString()
  const kdf = readString()
  if (cipher.toString() !== 'none' || kdf.toString() !== 'none') {
    // Deliberately not decrypted here, even though the app can read encrypted
    // keys. This command's whole output is a link carrying the *seed* in
    // cleartext — it says so on the next-to-last line — so decrypting the file
    // first would move the key from one plaintext container to another and
    // change nothing about who can read it. What it would cost is a second
    // bcrypt_pbkdf implementation, in a language whose stdlib does not have
    // one, on the one path that already warns the user to treat its output as a
    // secret. The key this command makes is generated with no passphrase for
    // exactly this reason; this branch only fires for a key the user encrypted
    // afterwards, and the fix is theirs to apply.
    throw new Error('the key has a passphrase; pairing needs an unencrypted one — '
      + 'run `ssh-keygen -p -N "" -f ' + pairKeyPath() + '` to remove it, or delete the '
      + 'file to have a fresh one made')
  }
  readString() // kdf options
  blob.readUInt32BE(offset); offset += 4 // number of keys
  readString() // public key blob
  const privateBlob = readString()
  let inner = 0
  const innerString = () => {
    const length = privateBlob.readUInt32BE(inner)
    inner += 4
    const value = privateBlob.subarray(inner, inner + length)
    inner += length
    return value
  }
  const check1 = privateBlob.readUInt32BE(inner); inner += 4
  const check2 = privateBlob.readUInt32BE(inner); inner += 4
  // Equal check integers are how a reader knows the key was decrypted with the
  // right passphrase. They are always equal here, and checking anyway means a
  // file that is not what it claims fails here rather than at the first byte of
  // a key the phone would then never authenticate with.
  if (check1 !== check2) throw new Error('the key file is malformed (check integers differ)')
  if (innerString().toString() !== 'ssh-ed25519') {
    throw new Error('only ed25519 keys can be paired')
  }
  innerString() // public key
  const privateKey = innerString()
  if (privateKey.length < 32) throw new Error('private key is too short')
  return privateKey.subarray(0, 32)
}

/// Sets up Easy Pair: makes sure the host has a key, authorises it, and prints
/// the link the app opens.
///
/// Generating rather than reusing `ssh-agent`'s or a hardware key's is the
/// point of the command — the phone has to hold the private half, so the host
/// needs a key whose private half can be handed over, and `~/.ssh/id_ed25519`
/// reused by other tools is exactly the key that must not be. So a dedicated
/// `~/.ssh/cqutmux_ed25519` is what this makes, and only its public half goes
/// into `authorized_keys`.
async function pair() {
  const address = pairAddress()
  // The machine's IP if it has one, else the hostname: the phone reaches this
  // over the network, and `localhost` in a saved host is a bug that only shows
  // up later.
  const host = address === '127.0.0.1' ? hostname() : address
  const keyPath = pairKeyPath()
  const comment = `cqutmux@${hostname()}`

  // An existing key is reused, so re-pairing a phone does not invalidate the one
// already paired. Checked before generating rather than by catching a failure:
// `ssh-keygen -f` on a path that exists asks "Overwrite (y/n)?" on stdin, so
// the catch-based version does not fail — it waits forever for an answer the
// command never gives, and a `cqutmux pair` that hangs with no output is far
// worse to diagnose than one that errors.
let seed
if (existsSync(keyPath)) {
  try {
    seed = privateKeySeed(await readFile(keyPath, 'utf8'))
  } catch (error) {
    process.stderr.write(`cqutmux: ${keyPath} exists but could not be read: ${error.message}\n`)
    process.stderr.write('cqutmux: move it aside and run this again to make a new one.\n')
    process.exit(1)
  }
} else {
  try {
    // `-N ''` because a passphrase would have to reach the phone through the
    // same link, which is the same secret twice.
    await run('ssh-keygen', ['-t', 'ed25519', '-N', '', '-C', comment, '-f', keyPath])
    seed = privateKeySeed(await readFile(keyPath, 'utf8'))
  } catch (error) {
    process.stderr.write(`cqutmux: could not make a key: ${error.message}\n`)
    process.exit(1)
  }
}

  const publicLine = (await readFile(`${keyPath}.pub`, 'utf8')).trim()
  const authorized = join(homedir(), '.ssh', 'authorized_keys')
  let existing = ''
  try { existing = await readFile(authorized, 'utf8') } catch { /* none yet is fine */ }
  if (!existing.split('\n').some(line => line.trim() === publicLine)) {
    await mkdir(dirname(authorized), { recursive: true })
    await appendFile(authorized, existing.endsWith('\n') || !existing ? publicLine + '\n' : '\n' + publicLine + '\n')
    await chmod(authorized, 0o600)
    process.stdout.write(`Authorised ${keyPath}.pub in ${authorized}\n\n`)
  }

  const items = [
    'v=1',
    `host=${pairEscape(host)}`,
    `port=${args.port}`,
    `user=${pairEscape(args.user)}`,
    `name=${pairEscape(hostname())}`,
  ]
  if (args.token) items.push(`token=${pairEscape(args.token)}`)
  const link = `cqutmux://pair?${items.join('&')}#key=${pairEscape(seed.toString('base64'))}`

  process.stdout.write('Scan this with the app (Add Host → Pair a Host):\n\n')
  process.stdout.write(qrTerminal(link) + '\n\n')
  process.stdout.write(`${link}\n\n`)
  process.stdout.write('The link contains the private key. Treat it as a secret:\n')
  process.stdout.write('it is not encrypted, and anyone who reads it can log in as you.\n')
  if (!args.token) {
    process.stdout.write('No gateway token is set, so this link carries none.\n')
  }
}

/// Reports whether a gateway is answering here, and what it says. Reads the
/// health endpoint rather than trusting a pid file, because a stale pid file is
/// exactly the thing this command exists to catch.
async function status(asJson) {
  const url = `${baseUrl()}/health`
  note(`GET ${url}${args.token ? ' (token set)' : ' (no token)'}`)
  try {
    const response = await fetch(url, { headers: authHeaders() })
    if (!response.ok) {
      if (asJson) return emitStatusJson({ running: false, url: baseUrl(), port: args.port, error: `HTTP ${response.status}` })
      process.stderr.write(`cqutmux: gateway answered ${response.status} at ${baseUrl()}\n`)
      process.exit(1)
    }
    const body = await response.json()
    if (asJson) {
      return emitStatusJson({
        running: true,
        url: baseUrl(),
        port: args.port,
        events: body.events,
        pendingApprovals: body.pendingApprovals,
        uptime: body.uptime,
        version: VERSION,
        configPath: Object.keys(config.values).some(k => k.startsWith('gateway.')) ? config.path : null,
      })
    }
    process.stdout.write(`running on ${baseUrl()}\n`)
    process.stdout.write(`events   ${body.events}\n`)
    process.stdout.write(`pending  ${body.pendingApprovals}\n`)
    process.stdout.write(`uptime   ${body.uptime}s\n`)
    process.stdout.write(`config   ${Object.keys(config.values).some(k => k.startsWith('gateway.'))
      ? config.path : 'defaults'}\n`)
  } catch (error) {
    if (asJson) return emitStatusJson({ running: false, url: baseUrl(), port: args.port, error: error.message })
    process.stderr.write(`cqutmux: no gateway at ${baseUrl()} (${error.message})\n`)
    process.exit(1)
  }
}

/// One object, one line of stdout, and a non-zero exit when nothing is running
/// — the shape a script wants. The human-readable `status` and this share the
/// same probe so the two cannot disagree about whether a gateway is up; only
/// the rendering differs.
///
/// A missing gateway is reported *in* the JSON as well as by the exit code: a
/// script that captures stdout and ignores the status would otherwise parse an
/// empty string and have to guess why.
function emitStatusJson(payload) {
  process.stdout.write(JSON.stringify(payload) + '\n')
  if (!payload.running) process.exit(1)
}

function authHeaders() {
  return args.token ? { authorization: `Bearer ${args.token}` } : {}
}

/// Where the gateway is, as the *client* commands see it.
///
/// Normally the loopback port the gateway runs on. `--base-url` overrides it
/// for the case the loopback cannot express: the gateway is on another machine
/// and reached through an SSH port-forward, so the port is right but the host
/// is not. A one-shot flag rather than a config key because the forward is a
/// property of the shell you are in, not of the host's configuration.
function baseUrl() {
  const override = flagValue('--base-url')
  // A trailing slash is what a URL pasted out of a browser has, and joining it
  // with `/health` would produce `//health`.
  return (override || `http://127.0.0.1:${args.port}`).replace(/\/+$/, '')
}

/// Whether a one-shot flag was passed, and what it was given.
function flagValue(name) {
  const index = argv.indexOf(name)
  if (index === -1) return null
  const value = argv[index + 1]
  // A flag at the end with nothing after it, or followed by another flag, is a
  // mistake worth refusing rather than treating as an empty string.
  if (value === undefined || value.startsWith('-')) {
    process.stderr.write(`cqutmux: ${name} needs a value\n`)
    process.exit(1)
  }
  return value
}

/// Whether `--verbose` was passed.
///
/// Gates the extra detail — the resolved base URL, the request that was made,
/// the raw reply — that a person debugging a forward wants and that a script
/// piping the output does not.
function verbose() {
  return argv.includes('--verbose') || argv.includes('-v')
}

/// Marks a line as diagnostic, so a caller filtering the command's real output
/// can drop these by prefix.
function note(message) {
  if (verbose()) process.stderr.write(`cqutmux: ${message}\n`)
}

/// Checks the things that actually stop the app from working, in the order they
/// would bite. Each one prints what it found and why it matters, because a bare
/// "ERROR" leaves the user to guess which of these the app will trip over.
async function doctor(repair = false) {
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
    const response = await fetch(`${baseUrl()}/health`, { headers: authHeaders() })
    check(response.ok, 'gateway', baseUrl())
  } catch {
    check(false, 'gateway', `not running on ${baseUrl()}; start it with \`cqutmux serve\``)
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

  // `--yes` repairs what a repair can honestly fix. It is deliberately narrow:
// a missing tmux or a gateway that is not running is not something this
// command can conjure, and a `doctor --yes` that "fixed" either by pretending
// would be worse than one that says so. What it does repair is the hook
// wiring, which `install` already knows how to write and which is the failure
// a user most often cannot diagnose by hand.
  if (repair) {
    const bridge = join(import.meta.dirname, 'claude-code-hook.sh')
    const target = join(homedir(), '.claude', 'settings.json')
    let needed = true
    try {
      const parsed = JSON.parse(await readFile(target, 'utf8'))
      needed = !Object.values(parsed.hooks ?? {}).some(groups =>
        (Array.isArray(groups) ? groups : []).some(group => isOurs(group, bridge)))
    } catch {
      // Missing or unparseable: `install` reports the unparseable case itself
      // rather than overwriting the user's file, so hand it the decision.
      needed = true
    }
    if (needed) {
      process.stdout.write('\n--yes: installing the agent hooks\n')
      await install([])
      failures = 0
    } else {
      process.stdout.write('\nhooks already wired\n')
    }
  }

  process.stdout.write(failures === 0 ? '\nready\n' : `\n${failures} thing(s) to fix\n`)
  if (failures > 0) process.exit(1)
}

/// `cqutmux update` — re-run the installer and say what version it landed.
///
/// There is no downloader here on purpose: the gateway is a plain Node script
/// that ships with the app's repository, and a `cqutmux update` that fetched
/// and ran code from the network would be a much larger thing to trust than the
/// problem it solves. What this does is what a user actually needs after
/// pulling a new checkout — re-wire the hooks so a changed bridge path or a
/// new event is picked up — plus a version report so the other end can be told
/// apart from an old install.
async function update(argv) {
  process.stdout.write(`cqutmux ${VERSION} at ${import.meta.dirname}\n`)
  await install(argv)
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

/// The agents this installer knows how to wire.
///
/// Each entry carries its own format, because one generic writer would be wrong
/// for at least three of these: Claude Code, Cursor and Antigravity all nest
/// `{type, command}` under an event, but Antigravity keys its events under a
/// *named* hook object, Kimi uses TOML, and Codex needs a feature flag before
/// its hooks are even read at all. The schemas are the agents' own documented
/// ones, with the source beside each.
///
/// `events` maps the agent's own event name to the kind the gateway records.
/// Only events the agent documents appear, so nothing here invents a name and
/// hopes.
///
/// OpenCode is deliberately absent: it documents no declarative command hook,
/// only a JavaScript plugin API. A config entry it would ignore is worse than
/// no entry, because it looks wired up.
function agentHooks() {
  const claudeBridge = join(import.meta.dirname, 'claude-code-hook.sh')
  const nodeBridge = join(import.meta.dirname, 'agent-hook.mjs')
  return [
    {
      id: 'claude-code',
      label: 'Claude Code',
      // https://docs.claude.com/en/docs/claude-code/hooks
      path: join(homedir(), '.claude', 'settings.json'),
      format: 'claude',
      bridge: claudeBridge,
      // The shell bridge predates the shared one and carries the Claude Code
      // payload field names directly; changing it would rewrite every existing
      // install's hook command for no gain.
      command: kind => `"${claudeBridge}" ${kind}`,
      ours: group => isOurs(group, claudeBridge),
    },
    {
      id: 'codex',
      label: 'Codex CLI',
      // https://developers.openai.com/codex/hooks
      path: join(homedir(), '.codex', 'hooks.json'),
      format: 'claude', // same nested {type, command} shape
      bridge: nodeBridge,
      command: kind => `"${nodeBridge}" codex ${kind}`,
      ours: group => isOurs(group, nodeBridge),
      // Codex ignores hooks entirely unless this is set, so installing them
      // without it would write a file that does nothing — the exact failure
      // that is impossible to debug from the app's side.
      tomlFeature: join(homedir(), '.codex', 'config.toml'),
      events: { PreToolUse: 'approval', Stop: 'notice' },
    },
    {
      id: 'cursor',
      label: 'Cursor',
      // https://cursor.com/docs/hooks
      path: join(homedir(), '.cursor', 'hooks.json'),
      format: 'cursor', // {version, hooks: {camelCaseEvent: [...]}}
      bridge: nodeBridge,
      command: kind => `"${nodeBridge}" cursor ${kind}`,
      // Cursor's entries put `command` directly on the entry, unlike the
      // nested `{hooks: [{command}]}` the others use — so this cannot share
      // `isOurs`, which looks inside a `hooks` array.
      ours: hook => typeof hook?.command === 'string' && hook.command.includes(nodeBridge),
      versionKey: true,
      events: { preToolUse: 'approval', stop: 'notice' },
    },
    {
      id: 'kimi-code',
      label: 'Kimi Code CLI',
      // https://moonshotai.github.io/kimi-code/en/customization/hooks
      path: join(homedir(), '.kimi-code', 'config.toml'),
      format: 'kimi-toml',
      bridge: nodeBridge,
      command: kind => `"${nodeBridge}" kimi ${kind}`,
      events: { PreToolUse: 'approval', Stop: 'notice' },
    },
    {
      id: 'antigravity',
      label: 'Antigravity',
      // https://antigravity.google/docs/hooks
      path: join(homedir(), '.gemini', 'config', 'hooks.json'),
      format: 'antigravity', // {name: {Event: [{matcher, hooks: [...]}]}}
      bridge: nodeBridge,
      command: kind => `"${nodeBridge}" antigravity ${kind}`,
      events: { PreToolUse: 'approval', PostInvocation: 'notice' },
    },
  ]
}

/// Writes one agent's hooks, in that agent's own format.
///
/// Every writer follows the same three rules, which are what make a re-run and
/// an uninstall safe:
///
///   1. Read and parse the existing file first; if it does not parse, stop and
///      say so rather than overwriting it. The file may hold the user's own
///      hooks, and guessing at a broken one risks their work.
///   2. Keep everything that is not ours, matched by the bridge path in the
///      command. An installer that drops someone's hooks is worse than none.
///   3. Back up the original the first time, so a mistaken install is
///      reversible by hand.
async function installAgentHooks(agent, dryRun) {
  const events = agent.events ?? { PreToolUse: 'approval', Stop: 'notice' }
  const additions = Object.entries(events).map(([event, kind]) => [event, agent.command(kind)])

  // TOML files (Kimi, and Codex's feature flag) are edited as text: a TOML
  // round-trip through a parser would reformat the user's whole config, and the
  // file is the user's.
  if (agent.format === 'kimi-toml') {
    return installKimi(agent, additions, dryRun)
  }

  const existing = await readJson(agent.path)
  const merged = structuredClone(existing ?? {})

  if (agent.format === 'cursor') {
    merged.version ??= 1
    merged.hooks ??= {}
    for (const [event, command] of additions) {
      const current = Array.isArray(merged.hooks[event]) ? merged.hooks[event] : []
      const theirs = current.filter(hook => !agent.ours(hook))
      merged.hooks[event] = [...theirs, { type: 'command', command, timeout: 5 }]
    }
  } else if (agent.format === 'antigravity') {
    // Antigravity keys its events under a *named* hook object, so ours gets a
    // name — which also makes it removable without touching anything else.
    merged.cqutmux ??= {}
    for (const [event, command] of additions) {
      const groups = [{
        matcher: '*',
        hooks: [{ type: 'command', command, timeout: 5 }],
      }]
      if (event === 'PostInvocation') groups[0] = { hooks: [{ type: 'command', command, timeout: 5 }] }
      merged.cqutmux[event] = groups
    }
  } else {
    // Claude Code, and Codex's hooks.json, share the nested shape.
    merged.hooks ??= {}
    for (const [event, command] of additions) {
      const current = Array.isArray(merged.hooks[event]) ? merged.hooks[event] : []
      const theirs = current.filter(group => !agent.ours(group))
      merged.hooks[event] = [...theirs, { matcher: '*', hooks: [{ type: 'command', command }] }]
    }
  }

  if (dryRun) {
    process.stdout.write(`would write ${agent.path} (${agent.label}):\n`)
    process.stdout.write(JSON.stringify(merged, null, 2) + '\n')
    return
  }

  await writeJson(agent.path, merged, existing !== null)
  await chmod(agent.bridge, 0o755).catch(() => {})
  process.stdout.write(`installed hooks for ${agent.label} in ${agent.path}\n`)

  // Codex reads no hooks at all until the feature flag is on. Writing a file it
  // ignores is the failure that cannot be diagnosed from the phone, so the flag
  // is set here and the reason printed.
  if (agent.tomlFeature) {
    const changed = await ensureTomlFeature(agent.tomlFeature, 'features.hooks', true, dryRun)
    if (changed) {
      process.stdout.write(`  enabled features.hooks in ${agent.tomlFeature} (Codex ignores hooks without it)\n`)
    }
  }
}

/// Kimi Code CLI's hooks are a TOML array of tables, and the docs are explicit
/// that an unknown field makes the whole config fail to load — so the four
/// documented fields are the only ones written.
async function installKimi(agent, additions, dryRun) {
  let text = ''
  try {
    text = await readFile(agent.path, 'utf8')
  } catch (error) {
    if (error.code !== 'ENOENT') throw error
  }

  // Our blocks are recognised by the bridge path inside them, and an existing
  // block runs from its `[[hooks]]` header to the next one.
  const blocks = text.split(/(?=^\[\[hooks\]\])/m)
  const kept = blocks.filter(block => !block.includes(agent.bridge))
  const ours = additions.map(([, command]) => `[[hooks]]
event = "${additions.find(([, c]) => c === command)[0]}"
command = "${command}"
`)

  const header = kept.join('').trimEnd()
  const next = [header, ...ours].filter(Boolean).join('\n\n') + '\n'

  if (dryRun) {
    process.stdout.write(`would write ${agent.path} (${agent.label}):\n${next}`)
    return
  }
  await writeFileWithBackup(agent.path, next, text || null)
  process.stdout.write(`installed hooks for ${agent.label} in ${agent.path}\n`)
}

/// Flips a `key = value` in the `[section]` of a TOML file, adding the section
/// if it is missing. Returns whether anything changed.
///
/// Text-level on purpose: the file is the user's, and a full TOML parse and
/// re-emit would rewrite every comment and every key order in it.
async function ensureTomlFeature(path, key, value, dryRun) {
  const [section, name] = key.split('.')
  let text = ''
  try {
    text = await readFile(path, 'utf8')
  } catch (error) {
    if (error.code !== 'ENOENT') throw error
  }

  const sectionPattern = new RegExp(`^\\[${section}\\]$`, 'm')
  const keyPattern = new RegExp(`^\\s*${name}\\s*=\\s*(true|false)\\s*$`, 'm')
  if (keyPattern.test(text)) {
    const next = text.replace(keyPattern, `${name} = ${value}`)
    if (next === text) return false
    if (!dryRun) await writeFileWithBackup(path, next, text)
    return true
  }

  const block = `[${section}]\n${name} = ${value}\n`
  const next = sectionPattern.test(text)
    ? text.replace(sectionPattern, block.trimEnd())
    : `${text.trimEnd()}${text.trim() ? '\n\n' : ''}${block}`
  if (!dryRun) await writeFileWithBackup(path, next, text || null)
  return true
}

/// Reads a JSON config, distinguishing "missing" (which becomes an empty
/// object) from "present but broken" (which stops the install).
async function readJson(path) {
  let raw
  try {
    raw = await readFile(path, 'utf8')
  } catch (error) {
    if (error.code === 'ENOENT') return null
    throw error
  }
  if (!raw.trim()) return null
  try {
    return JSON.parse(raw)
  } catch (error) {
    throw new Error(`${path} is not valid JSON (${error.message}); leaving it alone`)
  }
}

async function writeJson(path, value, backUp) {
  const text = JSON.stringify(value, null, 2) + '\n'
  await writeFileWithBackup(path, text, backUp ? await readFile(path, 'utf8').catch(() => null) : null)
}

/// Writes a file, keeping a one-time `.cqutmux-backup` of what was there.
async function writeFileWithBackup(path, text, existing) {
  await mkdir(dirname(path), { recursive: true })
  if (existing !== null && existing !== undefined) {
    const backup = `${path}.cqutmux-backup`
    if (!existsSync(backup)) await writeFile(backup, existing)
  }
  await writeFile(path, text)
}

async function install(argv) {
  const dryRun = argv.includes('--dry-run') || argv.includes('--print')

  // 1. Agent hook config. Claude Code first, because it is the one this tool
  // grew up with and the one a failure here matters most for.
  const claude = agentHooks().find(a => a.id === 'claude-code')
  await installClaude(claude, dryRun)

  // 1b. The rest, each in its own documented format. A failure on one does not
  // stop the others: a machine often has three of these installed and one
  // misconfigured, and refusing to wire the rest over it would be the wrong
  // trade.
  for (const agent of agentHooks()) {
    if (agent.id === 'claude-code') continue
    try {
      await installAgentHooks(agent, dryRun)
    } catch (error) {
      process.stderr.write(`cqutmux: could not wire ${agent.label}: ${error.message}\n`)
    }
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

/// Claude Code's own writer, kept separate only because its hook command is the
/// shell bridge rather than the shared Node one — the file format is identical
/// to Codex's.
async function installClaude(agent, dryRun) {
  const bridge = agent.bridge
  const target = agent.path

  const wanted = {
    PreToolUse: [{ matcher: '*', hooks: [{ type: 'command', command: `"${bridge}" approval` }] }],
    Stop: [{ hooks: [{ type: 'command', command: `"${bridge}" notice` }] }],
  }

  const existing = await readJson(target)
  const merged = structuredClone(existing ?? {})
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
    return
  }
  await writeJson(target, merged, existing !== null)
  await chmod(bridge, 0o755).catch(() => {})
  process.stdout.write(
    changed === 0
      ? `hooks already installed in ${target}\n`
      : `installed hooks in ${target}${existing !== null ? ` (backup: ${target}.cqutmux-backup)` : ''}\n`
  )
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

/// Publishes the token the hooks need, so they do not have to be configured
/// with it separately.
///
/// This closes a real hole: `install` tells the user to run the gateway with
/// `--token`, and the bridges are spawned by the agent with no environment of
/// ours at all — so they posted without an Authorization header and got a 401
/// that nothing surfaced. The hooks looked installed and no event ever reached
/// the inbox.
///
/// Written 0600 in the user's own directory, and only when a token is actually
/// set: a world-readable token file would be worse than the problem, and with
/// no token there is nothing to publish.
const tokenPath = join(homedir(), '.cqutmux', 'token')

function publishToken() {
  if (!args.token) return
  try {
    mkdirSync(dirname(tokenPath), { recursive: true })
    writeFileSync(tokenPath, args.token, { mode: 0o600 })
  } catch {
    // A read-only home is not a reason to refuse to start the gateway.
  }
}

/// Removes the published token on the way out, so a stopped gateway does not
/// leave a live secret lying around for the next program that reads it.
function retractToken() {
  try {
    if (existsSync(tokenPath)) rmSync(tokenPath, { force: true })
  } catch {
    // Best effort, as above.
  }
}

server.listen(args.port, '127.0.0.1', () => {
  publishToken()
  process.stderr.write(`[hook] listening on 127.0.0.1:${args.port} (token: ${args.token ? 'set' : 'none'})\n`)
  if (args.token) process.stderr.write(`[hook] token published to ${tokenPath} for the hooks\n`)
})

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    retractToken()
    // One helper process per simulator may be alive; stopping them here keeps a
    // stopped gateway from leaving private frameworks resident behind it.
    stopAllSessions()
    server.close(() => process.exit(0))
    // The listener above only fires if the server had not already closed; this
    // makes the exit happen either way rather than hanging a stopped daemon.
    setTimeout(() => process.exit(0), 200).unref()
  })
}

