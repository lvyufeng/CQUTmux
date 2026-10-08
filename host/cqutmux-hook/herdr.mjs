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