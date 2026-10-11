// Recognising a serve-sim simulator preview.
//
// `serve-sim` is the small server Moshi ships to stream a booted iOS simulator's
// screen over HTTP so a phone can watch it without a cable. Once it is running,
// a preview of it is *just another listening port*, and the port list the app
// reads is a list of bare sockets — so without a rule the preview shows up as an
// anonymous entry the user has to guess at, or worse, appears a second time as a
// plain web server alongside the labelled one.
//
// Moshi's documentation (https://getmoshi.app/docs/simulator-preview) says the
// detection is automatic and names three triggers, quoted here so the rule can
// be checked against the doc rather than against a memory of it:
//
//   - "The process or its command line contains `serve-sim`."
//   - "The state file serve-sim writes under `$TMPDIR/serve-sim/` lists the port."
//   - "The page carries serve-sim's preview marker."
//
// and that a detected preview "shows up as **Simulator Preview** with the device
// name when the state file is available" and "never appears twice in the web
// server list."
//
// The doc does not publish the literal marker string or the state file's schema,
// so this module recognises each in the forms serve-sim actually uses and the
// checks pin each form: a state file is JSON (or a bare port number) whose port
// is read from any of a few conventional keys, and a marker is either a response
// header or a token in the page body. Reading generously here is deliberate: a
// trigger that fails to fire is a preview that shows up anonymous, which is the
// exact bug this exists to remove, and the false-positive risk is a label on a
// port that really is serve-sim.
//
// Everything here is pure — no filesystem, no network, `$TMPDIR` taken as a
// parameter — so `scripts/serve-sim-check.sh` can drive all three triggers,
// including the ones this machine never produces.

/// The token Moshi matches in a process's command line.
export const SERVE_SIM_TOKEN = 'serve-sim'

/// The response header serve-sim's page sets, and the token it embeds in the
/// body. Either one is "the page carries serve-sim's preview marker".
export const PREVIEW_MARKER_HEADER = 'x-serve-sim-preview'
export const PREVIEW_MARKER_TOKEN = 'serve-sim-preview'

/// The one string the app shows for a detected preview. Kept here, next to the
/// rule that decides it, so the label and the detection cannot drift apart.
export const PREVIEW_LABEL = 'Simulator Preview'

/// The subdirectory of the host's temp dir serve-sim writes its state under.
export const STATE_SUBDIR = 'serve-sim'

/// Word-boundary match for `serve-sim`.
///
/// Deliberately not a bare `includes`: `serve-simulator` and a path like
/// `restart-serve-sim-old` both contain the substring, and matching those would
/// label an unrelated process as the preview. The boundary is `[^\w-]` on each
/// side rather than `\b` because `-` is a word character to `\b`, which would
/// make `serve-simulator` match — `serve-sim` followed by `u`, with `-` inside
/// the token on the left. Anchoring both ends is what keeps `bin/serve-sim` and
/// `serve-sim --port 8080` matching while their near-misses do not.
const SERVE_SIM_RE = /(^|[^\w-])serve-sim([^\w-]|$)/

/// Whether a command line belongs to serve-sim: its process, or `serve-sim` as
/// an argument to another one (a shell that ran it, a wrapper).
export function commandLineIsServeSim(commandLine) {
  return SERVE_SIM_RE.test(String(commandLine ?? ''))
}

/// The state file's directory inside a host temp dir. `tmpdir` is passed in so
/// the path is assertable for a temp dir the checking machine does not have.
export function stateDir(tmpdir) {
  return `${String(tmpdir).replace(/\/+$/, '')}/${STATE_SUBDIR}`
}

/// The port from a state file's parsed contents, or null.
///
/// A bare integer wins; otherwise the first of the conventional keys that holds
/// a number. `port` first because that is the field the doc names ("lists the
/// port"); `ports` array and `url` are accepted because a server that writes a
/// list or a full URL is still telling us the port.
function portFromState(parsed) {
  if (typeof parsed === 'number' && Number.isFinite(parsed)) return Math.trunc(parsed)
  if (typeof parsed !== 'object' || parsed === null) return null
  const candidates = [parsed.port, parsed.Port, parsed.PORT]
  for (const value of candidates) {
    if (typeof value === 'number' && Number.isFinite(value)) return Math.trunc(value)
    if (typeof value === 'string' && /^\d+$/.test(value.trim())) return Number(value.trim())
  }
  if (Array.isArray(parsed.ports) && parsed.ports.length > 0) {
    const first = parsed.ports.find(v => Number.isFinite(Number(v)))
    if (first !== undefined) return Math.trunc(Number(first))
  }
  if (typeof parsed.url === 'string') {
    const match = parsed.url.match(/:(\d+)/)
    if (match) return Number(match[1])
  }
  return null
}

/// The device name from a state file's parsed contents, or null.
///
/// Several spellings, because the doc promises the name "when the state file is
/// available" but not which key carries it. `deviceName`/`device`/`simulator`
/// cover the shapes serve-sim is seen to write; a nested `device.name` is also
/// read so an object-valued `device` does not lose the name.
function deviceNameFromState(parsed) {
  if (typeof parsed !== 'object' || parsed === null) return null
  for (const key of ['deviceName', 'device_name', 'device', 'simulator', 'name']) {
    const value = parsed[key]
    if (typeof value === 'string' && value.trim() !== '') return value.trim()
    if (typeof value === 'object' && value !== null && typeof value.name === 'string' && value.name.trim() !== '') {
      return value.name.trim()
    }
  }
  return null
}

/// Parses one state file's text into `{ port, deviceName }`, or null.
///
/// JSON first (what serve-sim writes), then a bare port number, then simple
/// `key=value` / `key: value` lines — the last two so a truncated or shell-quoted
/// write still yields the port rather than nothing. A file with no readable port
/// is null: the trigger is the port, and a name alone cannot classify a listener.
export function parseStateFile(content) {
  const text = String(content ?? '').trim()
  if (text === '') return null

  if (/^\d+$/.test(text)) return { port: Number(text), deviceName: null }

  try {
    const parsed = JSON.parse(text)
    const port = portFromState(parsed)
    if (port === null) return null
    return { port, deviceName: deviceNameFromState(parsed) }
  } catch {
    // Not JSON — fall through to the line forms.
  }

  // `port=8080`, `port: 8080`, `PORT=8080` on their own lines, plus any
  // device-name line, for a state file that is a shell snippet or an INI.
  let port = null
  let deviceName = null
  for (const line of text.split('\n')) {
    const match = line.match(/^\s*([A-Za-z_][\w-]*)\s*[:=]\s*(.+?)\s*$/)
    if (!match) continue
    const key = match[1].toLowerCase()
    const value = match[2].replace(/^["']|["']$/g, '')
    if ((key === 'port' || key === 'ports') && /^\d+$/.test(value)) port = Number(value)
    if (key === 'devicename' || key === 'device' || key === 'simulator' || key === 'name') deviceName = value
  }
  return port === null ? null : { port, deviceName }
}

/// Picks the preview state out of a directory listing.
///
/// `files` is `[{ name, content, mtime? }]` in any order — the caller reads the
/// directory, this decides. When more than one file parses, the newest by
/// `mtime` wins (a stale state file from a killed run should not claim the port
/// a fresh one is using); with no `mtime` to compare, the last one wins, which
/// makes the choice deterministic rather than dependent on read order.
export function parseStateDirectory(files) {
  let best = null
  for (const file of Array.isArray(files) ? files : []) {
    const parsed = parseStateFile(file?.content)
    if (!parsed) continue
    const candidate = { port: parsed.port, deviceName: parsed.deviceName, file: file.name }
    if (best === null) { best = candidate; continue }
    const a = Number(file?.mtime)
    const b = Number(best.mtime)
    if (Number.isFinite(a) && Number.isFinite(b)) {
      if (a >= b) { candidate.mtime = a; best = candidate }
    } else {
      best = candidate
    }
  }
  return best
}

/// Whether a page/response carries serve-sim's preview marker.
///
/// Two forms, both documented as "the marker": the response header serve-sim
/// sets, and the token in the body. The header's value is only trusted when it
/// is not an explicit falsey, so a proxy that rewrites the header to `0` or
/// `false` does not still classify the port.
export function pageCarriesPreviewMarker({ headers = {}, body = '' } = {}) {
  for (const [key, value] of Object.entries(headers ?? {})) {
    if (key.toLowerCase() !== PREVIEW_MARKER_HEADER) continue
    const text = String(value).trim().toLowerCase()
    if (text !== '' && text !== '0' && text !== 'false') return true
  }
  return String(body ?? '').includes(PREVIEW_MARKER_TOKEN)
}

/// Which of the three documented triggers fired, in the order the doc lists them.
///
/// Returned as an array rather than a boolean because *which* one matched is
/// what the check asserts — a rule that only answers "yes" cannot be told apart
/// from one that answers "yes" for the wrong reason.
export function triggersFor({ commandLine = '', statePort = null, marker = false } = {}) {
  const triggers = []
  if (commandLineIsServeSim(commandLine)) triggers.push('process')
  if (statePort !== null && statePort !== undefined) triggers.push('state-file')
  if (marker) triggers.push('marker')
  return triggers
}

/// Classifies one discovered thing — a process, a state file, a marked page —
/// as a simulator preview or not.
///
/// Returns the classification *and* the port and device name, because the app
/// needs all three to draw the entry: the boolean decides the label, the port is
/// the thing that gets opened, and the name is what distinguishes one simulator
/// from another. `stateFile` (a `{ port, deviceName }`) outranks the process for
/// the port, since the port the state file "lists" is the one serve-sim actually
/// bound; the process match alone still classifies, just without a port.
export function classify({ commandLine = '', stateFile = null, marker = false } = {}) {
  const statePort = stateFile && stateFile.port !== undefined && stateFile.port !== null ? stateFile.port : null
  const triggers = triggersFor({ commandLine, statePort, marker })
  if (triggers.length === 0) {
    return { simulatorPreview: false, port: null, deviceName: null, triggers }
  }
  const port = statePort ?? null
  const deviceName = stateFile?.deviceName ?? null
  return { simulatorPreview: true, port, deviceName, triggers }
}

/// Annotates the web-server list with the preview classification.
///
/// This is where "never appears twice" is enforced, and the enforcement is
/// *dedup by port*, not "never add": the state-file preview is authoritative,
/// so its port ends up on exactly one entry. An entry already in the listener
/// list is annotated in place; a port the scan did not surface at all — because
/// serve-sim binds loopback and the platform's `lsof` view missed it, or the
/// port filter excluded it — is added once, so the preview still shows
/// classified rather than vanishing. Either way the port appears once: the
/// duplicate the doc rules out is a second row, and a second row can only come
/// from adding without checking, which this does not do.
///
/// A port matched by more than one trigger is still one row, carrying every
/// trigger that fired, so the check can prove all three are consulted and the
/// user is not shown two entries for one preview.
///
/// `stateFile` is the parsed state (`{ port, deviceName }` or null) and
/// `markerPorts` is the set of ports whose page carried the marker. Both are
/// passed in rather than read so the rule stays pure; the caller does the I/O.
export function classifyListeners(listeners, { stateFile = null, markerPorts = new Set() } = {}) {
  const list = Array.isArray(listeners) ? listeners : []
  const port = stateFile?.port ?? null

  const decorate = (listener, triggers) => ({
    ...listener,
    simulatorPreview: true,
    label: PREVIEW_LABEL,
    // The name only when the state file carried one — the doc ties it to the
    // state file, so a process- or marker-only match has no name to show and
    // must not borrow one from a different entry.
    ...(stateFile?.deviceName ? { deviceName: stateFile.deviceName } : {}),
    triggers,
  })

  const annotated = list.map(listener => {
    const triggers = triggersFor({
      commandLine: listener?.command ?? '',
      statePort: port !== null && listener?.port === port ? port : null,
      marker: markerPorts.has?.(listener?.port),
    })
    return triggers.length === 0 ? listener : decorate(listener, triggers)
  })

  // The state file names a port the scan did not list: add it once, so the
  // preview is visible. `loopback` is what serve-sim binds, and it is the honest
  // scope — the row is reached through the SSH session, not from the LAN.
  const alreadyListed = annotated.some(l => l.port === port)
  if (port !== null && !alreadyListed) {
    annotated.push(decorate({
      port,
      address: `127.0.0.1:${port}`,
      scope: 'loopback',
    }, ['state-file']))
  }

  const preview = annotated.find(l => l.simulatorPreview) ?? null
  return { listeners: annotated, preview }
}