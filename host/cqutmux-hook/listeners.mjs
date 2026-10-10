// What is listening on a host, with enough about each one to recognise it.
//
// A bare port number cannot answer the question the preview screen is asking —
// "is this the dev server I started, or some system daemon?" — so each listener
// carries the process command, its pid, and the address it bound. Parsing is
// split out from the `lsof`/`ss` call so the rules can be checked with plain
// node: the failure here is a wrong label, which looks exactly like a right one.

/// Parses `lsof -nP -iTCP -sTCP:LISTEN` into one entry per listening socket.
///
/// lsof prints fixed columns — COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE
/// NAME — where NAME is the local address, `*:8080` or `127.0.0.1:5432`. The
/// command can contain spaces, so the split is by whitespace *runs* with the
/// first column taken whole; a naive `split(' ')` shifts every field for such a
/// process and reports a pid that belongs to nothing.
export function parseLsof(stdout) {
  const out = []
  for (const line of String(stdout).split('\n').slice(1)) {
    const fields = line.trim().split(/\s+/)
    if (fields.length < 3) continue
    // COMMAND comes first but may contain spaces — lsof prints the process name
    // as the kernel holds it, and "Google Chrome" is one such name. So the split
    // is not by position: PID is the first field that is all digits, and
    // everything before it is the command. Splitting on a single space shifts
    // every field for such a process and reports a pid that belongs to nothing.
    const pidIndex = fields.findIndex(f => /^\d+$/.test(f))
    if (pidIndex < 1) continue
    // NAME is the field before "(LISTEN)"; scan from the end so a command
    // containing a colon cannot be mistaken for the address.
    let address = null
    for (let i = fields.length - 1; i > pidIndex; i -= 1) {
      if (/:\d+$/.test(fields[i])) { address = fields[i]; break }
    }
    if (address === null) continue
    const port = portFromAddress(address)
    if (port === null) continue
    out.push({ command: fields.slice(0, pidIndex).join(' '), pid: Number(fields[pidIndex]), address, port })
  }
  return out
}

/// Parses `ss -ltn` (Linux) into the same shape, minus the command.
///
/// `ss -ltn` carries no process name unless run with `-p`, which needs root, so
/// these entries are honest about what they lack rather than inventing a name.
export function parseSs(stdout) {
  const out = []
  for (const line of String(stdout).split('\n').slice(1)) {
    const fields = line.trim().split(/\s+/)
    if (fields.length < 4) continue
    const address = fields[3]
    const port = portFromAddress(address)
    if (port === null) continue
    out.push({ address, port })
  }
  return out
}

/// The port from an `lsof`/`ss` local address (`*:8080`, `127.0.0.1:5432`,
/// `[::1]:3000`), or null when there is none to read.
export function portFromAddress(address) {
  const match = String(address).match(/:(\d+)$/)
  return match ? Number(match[1]) : null
}

/// A human name for the address a listener bound. The distinction that matters
/// on a phone is whether a dev server is reachable through the SSH session or
/// only from the host's own loopback — a `127.0.0.1`-only server is not
/// reachable even though its port is open.
export function scopeOf(address) {
  const host = String(address).replace(/:\d+$/, '')
  if (host === '127.0.0.1' || host === '::1' || host === '[::1]') return 'loopback'
  if (host === '*' || host === '0.0.0.0' || host === '[::]') return 'all'
  return 'address'
}

/// A framework label from the process command and any HTTP probe headers.
///
/// Command first, because it is always available; the headers only refine it,
/// and only when the server answered. A server that speaks HTTP but matches no
/// known framework is labelled `HTTP` rather than guessed at — a wrong
/// framework name is worse than none, because it is the thing the user reads to
/// decide whether this is the server they meant.
export function frameworkLabel({ command = '', headers = {} } = {}) {
  const cmd = command.toLowerCase()
  const powered = String(headers['x-powered-by'] ?? '').toLowerCase()
  const server = String(headers['server'] ?? '').toLowerCase()

  if (powered.includes('next.js') || cmd.includes('next')) return 'Next.js'
  if (cmd.includes('vite')) return 'Vite'
  if (powered.includes('express') || cmd.includes('express')) return 'Express'
  if (cmd.includes('webpack') || cmd.includes('webpack-dev-server')) return 'Webpack'
  if (cmd.includes('nuxt')) return 'Nuxt'
  if (cmd.includes('astro')) return 'Astro'
  if (powered.includes('php') || server.includes('php')) return 'PHP'
  if (server.includes('gunicorn') || cmd.includes('gunicorn')) return 'Gunicorn'
  if (server.includes('uvicorn') || cmd.includes('uvicorn')) return 'Uvicorn'
  if (server.includes('nginx')) return 'nginx'
  if (server.includes('apache') || server.includes('httpd')) return 'Apache'
  if (server.includes('caddy')) return 'Caddy'
  if (cmd.includes('python') || cmd.includes('python3')) return 'Python'
  if (cmd.includes('ruby') || cmd.includes('rails')) return 'Ruby'
  if (cmd.includes('node') || cmd.includes('deno') || cmd.includes('bun')) return 'Node'
  // Spoke HTTP but matched nothing: say so rather than leave it blank, which
  // would look like the probe failed.
  if (Object.keys(headers).length > 0) return 'HTTP'
  return null
}

/// Merges parsed sockets with the results of probing each one for HTTP.
///
/// The probe result is `{ headers }` for a server that answered or null for one
/// that did not, and both are kept: a port that refuses HTTP is still a listener
/// worth showing — it is just not a web server, and the label says which.
export function describe(sockets, probes = new Map()) {
  const byPort = new Map()
  for (const socket of sockets) {
    const existing = byPort.get(socket.port)
    // Prefer an entry that carries a command and a pid; `ss` gives neither.
    if (existing && existing.command && !socket.command) continue
    byPort.set(socket.port, socket)
  }
  return [...byPort.values()].map(socket => {
    const headers = probes.get(socket.port)?.headers ?? {}
    const speaksHttp = probes.has(socket.port)
    return {
      port: socket.port,
      ...(socket.command ? { command: socket.command } : {}),
      ...(socket.pid ? { pid: socket.pid } : {}),
      address: socket.address,
      scope: scopeOf(socket.address),
      ...(speaksHttp ? { http: true } : {}),
      ...(frameworkLabel({ command: socket.command, headers }) ? {
        framework: frameworkLabel({ command: socket.command, headers }),
      } : {}),
    }
  }).sort((a, b) => a.port - b.port)
}
