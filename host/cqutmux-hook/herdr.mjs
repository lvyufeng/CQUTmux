// Herdr integration for cqutmux-hook.
//
// Herdr (https://herdr.dev, Apache-2.0) is an agent multiplexer: it owns the
// terminals the agents run in and knows which of them are working, blocked or
// idle. That per-pane status is exactly what a phone needs, and it is something
// tmux and zellij cannot report.
//
// How this talks to it
// --------------------
// Herdr serves a newline-delimited JSON API over a *Unix* socket, and the app
// reaches the host through SSH `direct-tcpip`, which only forwards TCP — so
// the app cannot open that socket itself. The CLI is the bridge: `herdr api
// snapshot` returns the whole session state as one JSON document on stdout, and
// `herdr pane send-text` / `send-keys` drive a pane. Both run over the ordinary
// SSH exec channel the gateway already has, so nothing needs forwarding and no
// new daemon is involved.
//
// Everything here degrades quietly: if herdr is not installed, `status` says so
// and the routes return an empty board rather than an error. A host without
// herdr is the normal case, not a broken one.

import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { connect } from 'node:net'
import { homedir } from 'node:os'
import { join } from 'node:path'

const run = promisify(execFile)

// Herdr installs wherever the user put it; the installer's default is
// ~/.local/bin, and Homebrew is the other common one. A login shell is
// deliberately not used — see the note in SSHTransport.locate: sourcing rc
// files is slow and a stray `ssh-add` can hang it.
const DEFAULT_BIN = 'herdr'
// A snapshot has to walk every pane; a busy host can take a moment, but a
// minute of waiting means something is wrong rather than slow.
const SNAPSHOT_TIMEOUT_MS = 8000

function binary(args) {
  return args.herdrPath || DEFAULT_BIN
}

/**
 * A raw request over herdr's Unix socket.
 *
 * The CLI is enough for most of what the app needs, but it has a real gap:
 * `herdr pane focus` is *directional* — it moves to a neighbour and cannot name
 * a pane — so nothing in the CLI can jump to a pane the user picked from a
 * list. The socket API can: `pane.focus` takes a `pane_id`. The gateway runs on
 * the host, next to the socket, so it can speak it directly.
 *
 * One request per connection, newline-delimited, matching the CLI's own
 * envelope (`{id, method, params}`).
 */
export function callHerdrSocket(args, method, params, timeoutMs = 5000) {
  const socketPath = args.herdrSocket || join(homedir(), '.config', 'herdr', 'herdr.sock')
  return new Promise(resolve => {
    const id = `cqutmux:${method}`
    let buffer = ''
    let settled = false
    const finish = value => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      client.destroy()
      resolve(value)
    }

    const client = connect(socketPath)
    const timer = setTimeout(
      () => finish({ ok: false, reason: 'timeout', message: `${method} did not answer in time` }),
      timeoutMs
    )

    client.on('connect', () => client.write(JSON.stringify({ id, method, params }) + '\n'))
    client.on('data', chunk => { buffer += chunk })
    client.on('error', error =>
      finish({ ok: false, reason: 'socket', message: String(error.message || error) })
    )
    // The server may hold the connection open; the first newline-terminated
    // reply is the whole answer.
    client.on('data', () => {
      const newline = buffer.indexOf('\n')
      if (newline === -1) return
      const line = buffer.slice(0, newline)
      try {
        const parsed = JSON.parse(line)
        finish(parsed?.error
          ? { ok: false, reason: 'api', message: parsed.error.message || JSON.stringify(parsed.error) }
          : { ok: true, result: parsed?.result })
      } catch (error) {
        finish({ ok: false, reason: 'json', message: `could not parse the reply: ${line.slice(0, 200)}` })
      }
    })
    client.on('close', () => finish({ ok: false, reason: 'closed', message: 'socket closed before a reply' }))
  })
}

/**
 * Focuses a pane by id, so a jump from the app lands exactly where it was
 * asked to. Uses the socket because the CLI cannot express this.
 */
export async function herdrFocusPane(args, paneId) {
  if (!paneId || typeof paneId !== 'string') {
    return { ok: false, error: 'pane_id is required' }
  }
  const result = await callHerdrSocket(args, 'pane.focus', { pane_id: paneId })
  if (!result.ok) {
    return { ok: false, error: result.message || result.reason }
  }
  return { ok: true, paneId }
}

/**
 * Toggles zoom on herdr's focused pane.
 *
 * `pane.zoom` takes no pane_id and defaults to herdr's own focused pane, which
 * is the right target: the phone is looking at that pane's output, so zooming
 * anything else would full-screen something the user cannot see. The explicit
 * mode (rather than `toggle`) is what makes a pinch direction meaningful —
 * pinching out always zooms in, pinching back always zooms out, so the same
 * gesture does not mean different things on alternate pinches.
 *
 * The CLI has this too (`herdr pane zoom --on/--off`), and either works; the
 * socket is used because the gateway is already speaking it for `pane.focus`,
 * so one path is one thing to keep working.
 */
export async function herdrZoomPane(args, zoomed) {
  const result = await callHerdrSocket(args, 'pane.zoom', { mode: zoomed ? 'on' : 'off' })
  if (!result.ok) {
    return { ok: false, error: result.message || result.reason }
  }
  return { ok: true, zoomed: Boolean(zoomed), result: result.result ?? null }
}

async function callHerdr(args, argv, timeout = SNAPSHOT_TIMEOUT_MS) {
  const bin = binary(args)
  try {
    const { stdout } = await run(bin, argv, {
      timeout,
      maxBuffer: 8 * 1024 * 1024,
      // Herdr resolves its socket from the environment; without a HOME it
      // falls back to a path the daemon may not be listening on.
      env: process.env,
    })
    return { ok: true, stdout }
  } catch (error) {
    // Distinguish "not installed" from "installed but unhappy": the first is
    // ordinary and should not be logged as a fault, the second is worth seeing.
    const code = error.code
    if (code === 'ENOENT') {
      return { ok: false, reason: 'not-installed' }
    }
    return {
      ok: false,
      reason: 'failed',
      message: (error.stderr || error.message || String(error)).trim().slice(0, 400),
    }
  }
}

/** Whether herdr is on the host at all, and what version if so. */
export async function herdrStatus(args) {
  const result = await callHerdr(args, ['--version'], 5000)
  if (!result.ok) {
    return { installed: false, reason: result.reason, message: result.message }
  }
  return { installed: true, version: result.stdout.trim() }
}

/**
 * The current session state, flattened to what the phone renders.
 *
 * Herdr returns agents already keyed by pane with a status and a working
 * directory, which is most of what the UI needs; the workspaces and tabs are
 * pulled in so a pane can be shown under its workspace name rather than by id.
 */
export async function herdrSnapshot(args) {
  const result = await callHerdr(args, ['api', 'snapshot'])
  if (!result.ok) {
    return { installed: false, reason: result.reason, message: result.message, agents: [] }
  }

  let payload
  try {
    payload = JSON.parse(result.stdout)
  } catch {
    return { installed: true, error: 'herdr returned output that was not JSON', agents: [] }
  }

  // The CLI wraps the snapshot in the same envelope the socket API uses.
  const snapshot = payload?.result?.snapshot ?? payload?.snapshot ?? payload
  const workspaces = Array.isArray(snapshot?.workspaces) ? snapshot.workspaces : []
  const tabs = Array.isArray(snapshot?.tabs) ? snapshot.tabs : []
  const agents = Array.isArray(snapshot?.agents) ? snapshot.agents : []

  const label = new Map(workspaces.map(w => [w.workspace_id, w.label || w.workspace_id]))
  const tabLabel = new Map(tabs.map(t => [t.tab_id, t.label || t.tab_id]))

  return {
    installed: true,
    focusedPaneId: snapshot?.focused_pane_id ?? null,
    workspaces: workspaces.map(w => ({
      id: w.workspace_id,
      label: w.label || w.workspace_id,
      focused: Boolean(w.focused),
      paneCount: w.pane_count ?? 0,
      tabCount: w.tab_count ?? 0,
      status: w.agent_status || 'unknown',
    })),
    // The tabs are listed separately from the agents on purpose: a tab with no
    // agent running in it is still a tab the user can jump to, and deriving the
    // list from the agents would silently drop it.
    tabs: tabs.map(t => ({
      id: t.tab_id,
      label: t.label || t.tab_id,
      workspace: label.get(t.workspace_id) || t.workspace_id || '',
      focused: Boolean(t.focused),
      panes: (Array.isArray(snapshot?.panes) ? snapshot.panes : [])
        .filter(p => p.tab_id === t.tab_id)
        .map(p => ({
          // The pane's own label falls back to its position in the tab, which
          // is what herdr shows when a pane has not been renamed.
          paneId: p.pane_id,
          label: p.label || p.pane_id,
          tab: t.label || t.tab_id,
          workspace: label.get(p.workspace_id) || p.workspace_id || '',
          agent: p.agent || '',
          status: p.agent_status || 'unknown',
          cwd: p.foreground_cwd || p.cwd || '',
          focused: Boolean(p.focused),
        })),
    })),
    agents: agents.map(a => ({
      paneId: a.pane_id,
      agent: a.agent || 'agent',
      status: a.agent_status || 'unknown',
      workspace: label.get(a.workspace_id) || a.workspace_id || '',
      tab: tabLabel.get(a.tab_id) || a.tab_id || '',
      cwd: a.foreground_cwd || a.cwd || '',
      focused: Boolean(a.focused),
    })),
  }
}

/**
 * Answers an approval inside a pane.
 *
 * Herdr's key names are its own (`esc`, `Enter`, `C-c`). The pane is *not*
 * focused first: send-text and send-keys address a pane directly, verified
 * against a running server — a command sent to a background pane ran there
 * while another pane kept focus. Focusing first would have moved the user's
 * cursor for no reason, and `pane focus` is directional anyway, so it cannot
 * name a pane to focus.
 */
export async function herdrApprove(args, paneId, allow) {
  if (!paneId || typeof paneId !== 'string') {
    return { ok: false, error: 'pane_id is required' }
  }

  // Agents in a herdr pane read a plain y/n from the terminal, so this is the
  // same keystroke a person would type at the prompt.
  const key = allow ? 'y' : 'n'
  const sent = await callHerdr(args, ['pane', 'send-text', paneId, key], 5000)
  if (!sent.ok) {
    return { ok: false, error: `could not send to ${paneId}: ${sent.message || sent.reason}` }
  }
  const enter = await callHerdr(args, ['pane', 'send-keys', paneId, 'Enter'], 5000)
  if (!enter.ok) {
    return { ok: false, error: `sent the key but not Enter: ${enter.message || enter.reason}` }
  }

  return { ok: true, paneId, decision: allow ? 'allow' : 'deny' }
}

/** The visible text of a pane, so the phone can show what is being answered. */
export async function herdrRead(args, paneId, lines = 40) {
  if (!paneId || typeof paneId !== 'string') {
    return { ok: false, error: 'pane_id is required' }
  }
  const result = await callHerdr(args, ['pane', 'read', paneId], 5000)
  if (!result.ok) {
    return { ok: false, error: result.message || result.reason }
  }
  // The CLI prints the terminal text verbatim; keep the tail, which is where
  // the prompt being answered is.
  const text = result.stdout.replace(/\s+$/, '')
  const trimmed = text.split('\n').slice(-lines).join('\n')
  return { ok: true, paneId, text: trimmed }
}