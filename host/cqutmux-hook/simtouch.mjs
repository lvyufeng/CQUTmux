// Driving a booted Simulator's screen from the app: the host half.
//
// iOS has no supported way to inject a touch into the Simulator — `simctl` can
// screenshot and record but not tap — so the only route is CoreSimulator's
// private IndigoHID API. That API loads only into a process the Objective-C
// runtime takes over, and dlopen'ing SimulatorKit inside node crashes at load,
// so the injection lives in a separate helper (`simtouch/inject.swift`, built
// to `simtouch/cqutmux-simtouch`). This module owns those helpers: one child
// process per simulator, kept alive while the user is watching, spoken to over
// a line protocol.
//
// The helper is deliberately not started until the first gesture. Booting it
// loads two private frameworks and spins up an XPC connection, which is not
// worth doing for a preview someone opened to look at.

import { spawn } from 'node:child_process'
import { existsSync, statSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const helperSource = join(here, 'simtouch', 'inject.swift')
const helperBinary = join(here, 'simtouch', 'cqutmux-simtouch')

// A gesture the helper never answers means the child is wedged; give up rather
// than let a request hang forever. Generous, because the first gesture may
// include a lazy compile.
const REPLY_TIMEOUT_MS = 15_000
// A preview nobody is touching for this long should not keep the frameworks
// loaded and an XPC connection open.
const IDLE_SHUTDOWN_MS = 5 * 60_000

/// One simulator's helper process, and the gestures queued for it.
class Session {
  constructor(udid) {
    this.udid = udid
    this.child = null
    this.buffer = ''
    this.waiters = [] // { resolve, reject, timer }
    this.ready = null
    this.idleTimer = null
  }

  /// Starts the helper if it is not running. Rejects with a message that says
  /// what to fix, since every failure here is a host-setup problem rather than
  /// something the app can recover from.
  async start() {
    if (this.child) return
    ensureHelper()
    this.child = spawn(helperBinary, [this.udid], { stdio: ['pipe', 'pipe', 'pipe'] })
    this.child.stdout.setEncoding('utf8')
    this.child.stdout.on('data', chunk => this.onData(chunk))
    let stderr = ''
    this.child.stderr.setEncoding('utf8')
    this.child.stderr.on('data', chunk => { stderr += chunk })
    this.child.on('exit', (code, signal) => {
      const error = new Error(
        `simtouch helper for ${this.udid} exited (${signal || code})${stderr ? `: ${stderr.trim()}` : ''}`
      )
      for (const waiter of this.waiters.splice(0)) {
        clearTimeout(waiter.timer)
        waiter.reject(error)
      }
      this.child = null
      this.ready = null
    })

    // The helper prints a ready line once the frameworks loaded and the device
    // was found; the first gesture waits for it so a "no such simulator" error
    // comes back as a rejection instead of a lost touch.
    this.ready = new Promise((resolve, reject) => {
      this.readyResolve = resolve
      this.readyReject = reject
    })
    const timer = setTimeout(() => {
      reject(new Error(`simtouch helper for ${this.udid} did not become ready`))
    }, REPLY_TIMEOUT_MS)
    this.ready.then(() => clearTimeout(timer), () => clearTimeout(timer))
    // Nothing awaits this rejection when the helper is up and ready; keep node
    // from reporting it as unhandled.
    this.ready.catch(() => {})
    await this.ready
    this.touch()
  }

  /// Resets the idle countdown on every gesture, so the helper only goes away
  /// once the preview has genuinely been left alone.
  touch() {
    clearTimeout(this.idleTimer)
    this.idleTimer = setTimeout(() => this.stop(), IDLE_SHUTDOWN_MS)
    this.idleTimer.unref?.()
  }

  stop() {
    clearTimeout(this.idleTimer)
    if (!this.child) return
    const child = this.child
    this.child = null
    child.kill()
  }

  onData(chunk) {
    this.buffer += chunk
    let newline
    while ((newline = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, newline)
      this.buffer = this.buffer.slice(newline + 1)
      if (!line.trim()) continue
      let message
      try {
        message = JSON.parse(line)
      } catch {
        continue // a stray diagnostic line on stdout is not a reply
      }
      if (message.type === 'ready') {
        this.readyResolve?.()
        this.readyResolve = null
        continue
      }
      const waiter = this.waiters.shift()
      if (!waiter) continue
      clearTimeout(waiter.timer)
      if (message.ok) waiter.resolve({ ok: true })
      else waiter.reject(new Error(String(message.error || 'gesture rejected')))
    }
  }

  /// Sends one gesture and resolves when the helper has delivered it.
  async send(gesture) {
    if (!this.child) await this.start()
    await this.ready
    const line = JSON.stringify(gesture) + '\n'
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const index = this.waiters.findIndex(waiter => waiter.resolve === resolve)
        if (index >= 0) this.waiters.splice(index, 1)
        reject(new Error('the simulator did not acknowledge the touch'))
      }, REPLY_TIMEOUT_MS)
      this.waiters.push({ resolve, reject, timer })
      this.child.stdin.write(line, error => {
        if (error) {
          clearTimeout(timer)
          reject(error)
        }
      })
      this.touch()
    })
  }
}

/// Builds the helper from its Swift source if it is missing, or if the source
/// is newer than the binary — the source is the shipped artifact, the binary is
/// a cache, so an edited source must not be shadowed by a stale build.
function ensureHelper() {
  const source = statSync(helperSource)
  if (existsSync(helperBinary) && statSync(helperBinary).mtimeMs >= source.mtimeMs) return
  try {
    execFileSync('xcrun', ['swiftc', '-O', '-o', helperBinary, helperSource], {
      stdio: ['ignore', 'ignore', 'pipe'],
      timeout: 60_000,
    })
  } catch (error) {
    const detail = String(error.stderr || error.message || error).trim().slice(0, 400)
    throw new Error(
      'could not build the simulator touch helper (needs Xcode command line tools): ' + detail
    )
  }
}

const sessions = new Map()

/// Delivers one gesture to a simulator, starting the helper if needed.
export async function sendGesture(udid, gesture) {
  let session = sessions.get(udid)
  if (!session) {
    session = new Session(udid)
    sessions.set(udid, session)
  }
  try {
    return await session.send(gesture)
  } catch (error) {
    // A session whose helper died must not be reused: drop it so the next
    // gesture starts a fresh one rather than writing into a closed pipe.
    if (!session.child) sessions.delete(udid)
    throw error
  }
}

/// Stops every helper. Called on the gateway's own exit so a stopped daemon
/// does not leave one process per simulator behind.
export function stopAllSessions() {
  for (const session of sessions.values()) session.stop()
  sessions.clear()
}

/// Whether the helper's source is present, for the health endpoint.
export function touchHelperAvailable() {
  return existsSync(helperSource)
}