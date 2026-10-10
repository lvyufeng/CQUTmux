// Multiplexer diagnostics for `cqutmux doctor`.
//
// The session picker discovers tmux / zellij / herdr through a *preflight*: one
// shell script sent over the SSH connection the app already has. The gateway
// resolves the same programs separately, from its own process environment. The
// two are not guaranteed to agree — the app's preflight is a fresh `sh -lc` with
// a PATH this repo does not control, and the gateway is a long-lived daemon that
// inherited whatever PATH its supervisor had at login.
//
// When they disagree the failure is invisible from the app. A tmux the picker
// finds and the daemon does not still means the session list is empty and the
// tmux tab simply never appears; a *duplicate* install is worse, because both
// halves work and quietly address different servers. Neither prints an error,
// and neither is reproducible on a machine where the two PATHs happen to match.
//
// So `doctor` reproduces the preflight and reports what each side resolves.
//
// This module is deliberately pure — it builds a script and reads a string, and
// spawns nothing. The decisions (PATH order, duplicate and mismatch rules) are
// the part that breaks on a host nobody is looking at, and keeping them pure is
// what lets `scripts/mux-doctor-check.sh` assert them without such a host.

/// The directories the preflight puts *ahead* of the user's own PATH.
///
/// The order is the whole point. A conda or miniforge tmux normally sits last
/// on a login PATH; here `/usr/bin` comes before the user's additions, so the
/// picker resolves the distro binary while an interactive shell resolves the
/// conda one. Reproducing the list — rather than running `command -v` with the
/// ambient PATH — is what makes this diagnosis match what the picker sees.
export const PROBE_PATH_DIRS = [
  '$HOME/.local/bin',
  '$HOME/bin',
  '/home/linuxbrew/.linuxbrew/bin',
  '$HOME/.nix-profile/bin',
  '/nix/var/nix/profiles/default/bin',
  '/opt/homebrew/bin',
  '/usr/local/bin',
  '/opt/local/bin',
  '/usr/bin',
  '/bin',
]

/// The multiplexers the picker is able to offer, in the order it probes them.
export const MUX_NAMES = ['tmux', 'zellij', 'herdr']

/// A version string reduced to the token that actually distinguishes builds.
///
/// `tmux -V` prints `tmux 3.5a` and `zellij -V` prints `zellij 0.40.1`, while
/// tmux's own `#{version}` format prints the bare `3.5a`. Comparing the raw
/// strings would call `3.5a` and `tmux 3.5a` a mismatch forever — a warning
/// that fires on every healthy host is worse than no warning, because it is the
/// one the reader learns to skip.
export function versionToken(text) {
  if (!text) return null
  const parts = String(text).trim().split(/\s+/)
  return parts.length ? parts[parts.length - 1] : null
}

/// The argv a preflight runs, for a given list of program names.
///
/// `sh -lc` rather than the login shell, and the distinction is real: bash
/// sources `~/.bashrc` for a non-interactive SSH command, so `ssh host
/// 'command -v tmux'` answers a *different* question than the picker asked.
/// The script is one string because that is how it crosses the wire — the picker
/// exports the same PATH and runs the same probes.
///
/// Listing every copy is how a duplicate install is found; `command -v` alone
/// shows only the first and reports the same thing whether there is one tmux or
/// three.
///
/// The obvious form, `command -v -a`, does not exist: bash's `command` rejects
/// `-a` ("command: -a: invalid option") and `/bin/sh` is bash on macOS, so a
/// probe that relied on it would silently answer nothing on the very machine
/// this was written on — and an empty answer reads as "not installed", which is
/// a *wrong* diagnosis rather than a degraded one. `which -a` is the portable
/// way to enumerate, with `command -v` covering a host where `which` is absent
/// (the list is then one long, which degrades duplicate detection rather than
/// breaking it). `awk '!seen[$0]++'` de-duplicates while *keeping PATH order*,
/// because the first entry is the one the picker actually runs.
///
/// `grep '^/'` keeps only absolute paths: a `which` that answers "tmux not
/// found" on stdout would otherwise be recorded as a binary named `not`.
export function probeScript(names = MUX_NAMES) {
  const path = [...PROBE_PATH_DIRS, '$PATH'].join(':')
  const lines = [`export PATH="${path}"`]
  for (const name of names) {
    const probe = `{ command -v ${name} 2>/dev/null; which -a ${name} 2>/dev/null; }`
    lines.push(`${probe} | grep '^/' | awk '!seen[$0]++' | sed 's|^|cqutmux-bin ${name} |'`)
    // The version matters because tmux refuses to talk to a server started by a
    // different build, and the picker treats that refusal the same as an empty
    // list — so a version split reads as "no sessions", not as an error.
    lines.push(`${name} -V 2>/dev/null | sed 's|^|cqutmux-ver ${name} |'`)
  }
  return lines.join('\n')
}

/// Reads `probeScript`'s output back into copies and versions per name.
///
/// Anything that is not one of our own prefixed lines is ignored rather than
/// guessed at: an unrecognised line is a shell's own noise (a banner, a warning
/// from an rc file), and folding it into a path list would invent a binary that
/// does not exist.
export function parseProbe(text) {
  const copies = {}
  const versions = {}
  for (const raw of String(text ?? '').split('\n')) {
    const line = raw.trim()
    if (!line) continue
    const bin = line.match(/^cqutmux-bin (\S+) (.*)$/)
    if (bin) {
      const [, name, path] = bin
      ;(copies[name] ??= []).push(path.trim())
      continue
    }
    const ver = line.match(/^cqutmux-ver (\S+) (.*)$/)
    if (ver) {
      const [, name, version] = ver
      versions[name] = version.trim()
    }
  }
  return { copies, versions }
}

/// One multiplexer's diagnosis, before it is rendered.
///
/// `status` is what the report keys off, and the problem states are kept apart
/// on purpose because their fixes are different and a single "problem" would
/// point at the wrong one:
///
/// - `daemon-cannot-find` — the picker resolves it, the daemon does not. The
///   fix is a PATH for the service, not a symlink into the picker's path.
/// - `duplicate` — more than one *distinct* copy, so the picker and a shell can
///   be running different servers. The fix is the symlink Moshi prints.
/// - `version-mismatch` — the resolved binary is a different build from the
///   server actually serving the sessions, so it will refuse to talk to it.
/// - `server-unknown` — a server is up but refused to name its version; said
///   out loud, because "a server is up and unchecked" is not "no server is up".
///
/// `absent` is not a problem: a host without a multiplexer is the normal case.
export function diagnose({
  name,
  copies = [],
  version = null,
  daemonPath = null,
  serverVersion = null,
  serverUnknown = false,
}) {
  if (copies.length === 0) {
    return { name, status: 'absent', found: [], version, note: 'not installed', fix: null }
  }

  const primary = copies[0]

  if (daemonPath === null) {
    const dir = primary.replace(/\/[^/]*$/, '')
    return {
      name,
      status: 'daemon-cannot-find',
      found: copies,
      version,
      note: `the picker finds it at ${primary}, but the daemon cannot — its PATH does not include ${dir}`,
      fix: `add ${dir} to the PATH of whatever starts \`cqutmux serve\`, then restart it`,
    }
  }

  // A duplicate matters even when no server is running yet. Two tmux binaries
  // is the arrangement that produces *two servers*, and detecting it before one
  // is up is exactly when it explains a symptom — "a session I can see in my
  // terminal is missing from the picker". Waiting for a server to appear first
  // would diagnose it only after it had already bitten.
  const distinct = [...new Set(copies)]
  if (distinct.length > 1) {
    return {
      name,
      status: 'duplicate',
      found: copies,
      version,
      note: `${distinct.length} installs; the picker runs ${primary}`,
      fix: `ln -sf ${primary} ~/.local/bin/${name}  (or remove the stray copy)`,
    }
  }

  if (serverUnknown) {
    return {
      name,
      status: 'server-unknown',
      found: copies,
      version,
      note: `${primary}${version ? ` (${version})` : ''} — a server is running but its version could not be read`,
      fix: `if a session is missing from the picker, compare the server's own version against ${version ?? 'this binary'}`,
    }
  }

  if (serverVersion !== null && version !== null && serverVersion !== version) {
    return {
      name,
      status: 'version-mismatch',
      found: copies,
      version,
      note: `resolved ${version}, but the running server is ${serverVersion}`,
      fix: `the picker treats the mismatch as "no sessions"; stop the other server or symlink ${primary} over the one it runs`,
    }
  }

  return { name, status: 'ok', found: copies, version, note: primary, fix: null }
}

/// The `doctor` section, rendered as lines.
///
/// Returned rather than printed so the caller decides where it goes and a check
/// can read it. The labels are `ok` / `warn`, matching the rest of doctor's
/// vocabulary — a diagnostic that invents a third spelling for "fine" is one the
/// reader has to learn twice.
export function formatReport(diagnoses) {
  const lines = ['', 'Multiplexers']
  const present = diagnoses.filter(d => d.status !== 'absent')
  if (present.length === 0) {
    lines.push('  ok   none installed — the picker will not offer a session tab')
    return lines
  }
  for (const d of diagnoses) {
    if (d.status === 'absent') continue
    const label = d.status === 'ok' ? 'ok  ' : 'warn'
    const version = d.status === 'ok' && d.version ? ` (${d.version})` : ''
    lines.push(`  ${label} ${d.name.padEnd(6)} ${d.note}${version}`)
    if (d.fix) lines.push(`       ↳ ${d.fix}`)
  }
  return lines
}

/// Whether a diagnosis is something doctor should count against its exit code.
///
/// `ok`, `absent` and `server-unknown` do not fail a run: not installing a
/// multiplexer is normal, and a version we could not read is a caveat rather
/// than a fault. The three that mean "the picker and the daemon disagree" do.
export function isProblem(diagnosis) {
  return ['daemon-cannot-find', 'duplicate', 'version-mismatch'].includes(diagnosis.status)
}