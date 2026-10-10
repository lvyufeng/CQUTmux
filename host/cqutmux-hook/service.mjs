// Keeping the gateway running at login.
//
// `cqutmux serve` is a foreground process; stopping the shell that started it
// stops the gateway, and the app then finds nothing where it expected a host.
// Moshi solves this with `moshi-hook service install`, which registers a real
// service — launchd on macOS, a user unit on Linux, a logon entry on Windows.
//
// This module builds the *file* for each platform, and nothing here touches the
// filesystem or spawns a supervisor. That split is deliberate: the content of a
// unit is what is easy to get subtly wrong (a missing `RunAtLoad`, a relative
// program path, an argument that needs quoting), and keeping it pure is what
// lets `scripts/service-check.sh` assert it on a machine that runs neither
// platform's supervisor.

/// The label / unit name. One string, so launchd's `Label`, the plist filename
/// and the systemd unit agree by construction rather than by three literals.
export const SERVICE_ID = 'dev.cqutmux.gateway'

/// Where each platform's user-level unit lives, and what kind it is.
///
/// User-level, not system-wide, in every case: the gateway runs as the user who
/// owns the SSH keys and the tmux sessions, and a system service would run as
/// root with neither. `home` is passed in rather than read so the mapping can be
/// asserted for a platform this machine is not.
export function unitPlan({ platform = process.platform, home }) {
  if (platform === 'darwin') {
    return {
      kind: 'launchd',
      label: SERVICE_ID,
      path: `${home}/Library/LaunchAgents/${SERVICE_ID}.plist`,
    }
  }
  if (platform === 'win32') {
    // Moshi registers a per-user logon entry. We do not write one: this repo is
    // developed and checked on macOS and Linux, and a registry or Task Scheduler
    // file that has never been run is worse than a clear "not supported here".
    return { kind: 'unsupported', platform }
  }
  return {
    kind: 'systemd',
    label: SERVICE_ID,
    path: `${home}/.config/systemd/user/${SERVICE_ID}.service`,
  }
}

/// The command line the service runs.
///
/// `process.execPath` and the script's own path, not a bare `cqutmux`: a
/// service has no shell and no PATH, so a name that resolves in the user's
/// terminal resolves to nothing at login. The resolved absolute paths are the
/// one form that works without an environment.
export function serviceArgv({ nodePath, scriptPath, port, token }) {
  const args = [scriptPath, 'serve']
  if (port) args.push('--port', String(port))
  if (token) args.push('--token', token)
  return { program: nodePath, args }
}

/// XML-escapes a value for a plist `<string>`.
///
/// A token or a path can contain `&`, `<`, `>`, `"` or `'`, and an unescaped
/// one produces a plist that `launchctl` refuses to parse — a service that
/// silently never starts, which is the failure mode the whole feature exists to
/// prevent. Ampersand first: escaping it after the others would double-escape
/// the `&` in `&lt;`.
export function xmlEscape(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;')
}

/// A launchd agent plist.
///
/// `RunAtLoad` is what makes it start at login; without it the file is
/// registered and idle. `KeepAlive` restarts the gateway if it dies, which is
/// the difference between "runs at login" and "is running" — a gateway that
/// crashed an hour ago and stayed down is the same to the app as one never
/// installed. `StandardOutPath`/`StandardErrorPath` point at the same log
/// `cqutmux logs` reads, so a service-run gateway is visible where a foreground
/// one is.
export function launchdPlist({ program, args, logPath }) {
  const argXml = [program, ...args]
    .map(a => `      <string>${xmlEscape(a)}</string>`)
    .join('\n')
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${xmlEscape(SERVICE_ID)}</string>
    <key>ProgramArguments</key>
    <array>
${argXml}
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${xmlEscape(logPath)}</string>
    <key>StandardErrorPath</key>
    <string>${xmlEscape(logPath)}</string>
</dict>
</plist>
`
}

/// A systemd user unit.
///
/// The program and every argument are quoted independently, because systemd
/// splits `ExecStart` on whitespace itself and a path with a space — a home
/// directory under `/Users/First Last` — would otherwise arrive as two
/// arguments and the gateway would be asked to serve a directory that does not
/// exist. `WantedBy=default.target` is the user-manager equivalent of
/// `RunAtLoad`; `Restart=on-failure` matches launchd's `KeepAlive`.
export function systemdUnit({ program, args, logPath }) {
  const exec = [program, ...args].map(quoteSystemd).join(' ')
  return `[Unit]
Description=cqutmux gateway

[Service]
Type=simple
ExecStart=${exec}
Restart=on-failure
StandardOutput=append:${logPath}
StandardError=append:${logPath}

[Install]
WantedBy=default.target
`
}

/// Quotes one systemd argument.
///
/// Double quotes, with backslash escaping for the two characters systemd treats
/// specially inside them. A plain path is quoted too: quoting only when needed
/// makes the output differ between a machine with spaces in its home and one
/// without, and the unquoted path is the one that is never tested.
function quoteSystemd(arg) {
  return `"${String(arg).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`
}

/// The whole install, as a description rather than a side effect: which file,
/// its content, and the commands a human would run to load it.
export function servicePlan({ platform = process.platform, home, logPath, nodePath, scriptPath, port, token }) {
  const unit = unitPlan({ platform, home })
  const { program, args } = serviceArgv({ nodePath, scriptPath, port, token })
  if (unit.kind === 'unsupported') return { ...unit, supported: false }
  const content = unit.kind === 'launchd'
    ? launchdPlist({ program, args, logPath })
    : systemdUnit({ program, args, logPath })
  return {
    ...unit,
    supported: true,
    content,
    load: unit.kind === 'launchd'
      ? ['launchctl', 'load', '-w', unit.path]
      : ['systemctl', '--user', 'enable', '--now', `${SERVICE_ID}.service`],
    unload: unit.kind === 'launchd'
      ? ['launchctl', 'unload', '-w', unit.path]
      : ['systemctl', '--user', 'disable', '--now', `${SERVICE_ID}.service`],
    status: unit.kind === 'launchd'
      ? ['launchctl', 'list', SERVICE_ID]
      : ['systemctl', '--user', 'is-active', `${SERVICE_ID}.service`],
  }
}