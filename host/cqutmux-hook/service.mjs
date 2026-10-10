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

/// The Windows registry key the logon entry is written under.
///
/// `HKCU\...\Run` rather than a Task Scheduler XML or an `HKLM` key. A value
/// under `HKEY_CURRENT_USER` is a *per-user* logon entry that Windows runs as
/// the user who owns it and needs no elevation to write — which is exactly what
/// Moshi's `service install` does on Windows. An `HKLM` Run key would be
/// machine-wide and require an administrator, and a scheduled task (though more
/// capable, with restart and a working-directory) is a second schema to get
/// subtly wrong; the Run key is the simplest thing that starts the gateway at
/// login without a prompt. `reg` is the tool that writes it, and it is present
/// on every Windows since XP, so there is no extra dependency.
export const WINDOWS_RUN_KEY = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'

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
    // A per-user logon entry, written as a value under the user's own `Run` key.
    // `path` is the *registry key*, not a file: the value named `SERVICE_ID`
    // under it is what a logon entry is. No elevation is needed to write under
    // HKCU, which is the whole reason this shape was chosen (see
    // WINDOWS_RUN_KEY).
    //
    // A rule-level check only. This branch has never been executed on Windows:
    // the repo is developed and checked on macOS and Linux and has no Windows
    // machine in CI. The decisions — the key, the value name, the command line
    // and the `reg` verbs — are therefore kept pure and asserted by
    // `scripts/service-check.sh`, which is the strongest statement that can be
    // made here. The execution path in `index.mjs` is guarded on
    // `process.platform === 'win32'` so a macOS/Linux host can never run it.
    return {
      kind: 'win32',
      label: SERVICE_ID,
      path: WINDOWS_RUN_KEY,
      value: SERVICE_ID,
    }
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

/// Quotes one argument of a Windows `Run` value.
///
/// The value Windows executes is a single command line, parsed by the same
/// rules CreateProcess uses for `lpCommandLine` — not by a shell, so no `%VAR%`
/// expansion happens, but a path or token containing a space must still be
/// quoted or it arrives as two arguments. A literal `"` is escaped with a
/// backslash, which is what the CommandLineToArgvW convention asks for. A plain
/// path is left unquoted so the common output matches what a human would type.
function quoteWindows(arg) {
  const text = String(arg)
  if (!/[\s"]/.test(text)) return text
  return `"${text.replace(/"/g, '\\"')}"`
}

/// The command line stored in the `Run` value: program then args, quoted.
///
/// This is what Windows runs at login. Like the launchd and systemd forms it
/// carries the absolute node path and script path — a service has no shell and
/// no PATH, so a bare `cqutmux` would resolve to nothing at login.
export function windowsCommandLine({ program, args }) {
  return [program, ...args].map(quoteWindows).join(' ')
}

/// The `reg` command that writes the logon entry.
///
/// `reg add` both creates the key's value and is the "load": the Run key is
/// read by Windows at logon, so there is no separate load step as with launchd
/// or systemd. `/f` overwrites an existing value without prompting — a
/// reinstall must be an update, not a silent no-op. The value name is
/// SERVICE_ID, so `reg query`/`reg delete` address back the same entry the same
/// way `launchctl list <label>` does.
export function windowsRunAdd({ program, args }) {
  const commandLine = windowsCommandLine({ program, args })
  return ['reg', 'add', WINDOWS_RUN_KEY, '/v', SERVICE_ID, '/t', 'REG_SZ', '/d', commandLine, '/f']
}

/// The `reg delete` command that removes the logon entry.
///
/// No `/f` prompt: uninstalling is the intent, and a half-answered prompt would
/// leave the entry behind while the caller reports success.
export function windowsRunDelete() {
  return ['reg', 'delete', WINDOWS_RUN_KEY, '/v', SERVICE_ID, '/f']
}

/// The `reg query` command that reports whether the entry exists, and its
/// command line. `reg query` exits non-zero when the value is absent, which is
/// the same "not installed" signal `launchctl list` gives.
export function windowsRunQuery() {
  return ['reg', 'query', WINDOWS_RUN_KEY, '/v', SERVICE_ID]
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
///
/// `content` is the file to write on launchd and systemd, and `null` on
/// Windows: a Run entry is a registry value, not a file, and the whole install
/// is expressed by `load` there. The caller branches on the platform rather
/// than imagining a file where there is none.
export function servicePlan({ platform = process.platform, home, logPath, nodePath, scriptPath, port, token }) {
  const unit = unitPlan({ platform, home })
  const { program, args } = serviceArgv({ nodePath, scriptPath, port, token })

  if (unit.kind === 'win32') {
    return {
      ...unit,
      supported: true,
      content: null,
      // The `reg add` is both the write and the load: Windows reads the Run key
      // at logon, so there is no separate enable step.
      load: windowsRunAdd({ program, args }),
      unload: windowsRunDelete(),
      status: windowsRunQuery(),
    }
  }

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