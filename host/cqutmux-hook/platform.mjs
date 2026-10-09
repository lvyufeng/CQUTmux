// Native Windows hosts.
//
// A gateway running on Windows (under Node) needs two things done differently,
// and both are easy to get subtly wrong in a way that only shows up on the
// platform we cannot test on:
//
// 1. **Resolving a program.** `execFile('herdr', …)` relies on the shell's PATH
//    lookup and on `herdr` being an executable file. On Windows the installed
//    program is `herdr.exe` (or a `.cmd` shim from a package manager), and
//    `execFile` will not find it by the bare name — it wants the extension.
//    PowerShell's `Get-Command` is the equivalent of `command -v`: it answers
//    with the resolved path, or reports nothing when the program is absent.
// 2. **The socket.** herdr's API socket is a *Unix* domain socket on Linux and
//    macOS. On Windows, Node's `net.connect` to a named pipe means a `\\.\pipe\
//    <name>` path rather than a filesystem path, and the default location
//    differs. The socket path is therefore derived per platform rather than
//    hardcoded.
//
// This file is deliberately pure: it takes a platform string and returns a
// description of what to run. Nothing here spawns anything, so the decisions —
// which are the part that breaks on a machine nobody is looking at — can be
// checked without one. The check is `scripts/windows-host-check.sh`.

/** Where a program was found, and how to run it. */
export function resolveCommand(name, platform = process.platform) {
  if (platform === 'win32') {
    // `Get-Command -ErrorAction SilentlyContinue` prints the resolved path, or
    // nothing at all when the program is missing. The bare name works too on
    // modern PowerShell, but only for a real `.exe`; a `.cmd`/`.bat` shim (npm,
    // scoop, winget) needs the extension, and Get-Command is what resolves it.
    return {
      shell: 'powershell',
      argv: ['-NoProfile', '-NonInteractive', '-Command', `(Get-Command ${name} -ErrorAction SilentlyContinue).Source`],
      // A program with no output was not found. This is the same signal a
      // POSIX `command -v` gives, so the caller's "not installed" branch is
      // platform-independent.
      presentWhen: 'non-empty-stdout',
    }
  }
  // POSIX: let the shell find it, which is what `execFile` already does. The
  // probe exists so "is it installed" has one answer on every platform.
  return {
    shell: 'sh',
    argv: ['-c', `command -v ${name} || true`],
    presentWhen: 'non-empty-stdout',
  }
}

/**
 * The socket path herdr listens on, per platform.
 *
 * `platform` is a parameter rather than read from `process` inside so the whole
 * mapping can be asserted, including the branches this machine never takes.
 * `home` is passed in because Windows and POSIX disagree about where it lives
 * and `os.homedir()` is the wrong answer for a platform we are not on.
 */
export function socketPath(home, platform = process.platform) {
  if (platform === 'win32') {
    // A named pipe, not a file. herdr follows the Node convention of naming it
    // under the user's profile so two users on one machine do not collide.
    return `\\\\.\\pipe\\herdr-${sanitize(accountName(home))}`
  }
  return `${home}/.config/herdr/herdr.sock`
}

/** The account component of a Windows home path (`C:\Users\alice` → `alice`). */
function accountName(home) {
  const parts = String(home || '').split(/[\\/]/).filter(Boolean)
  return parts.length ? parts[parts.length - 1] : 'default'
}

/** A name safe to put in a pipe path: no separators, no spaces. */
function sanitize(name) {
  return String(name).replace(/[^A-Za-z0-9_.-]/g, '_') || 'default'
}

/**
 * The arguments to pass a resolved program so it prints its snapshot as JSON.
 *
 * Both platforms take `api snapshot`; the difference on Windows is that the
 * program name must be the resolved `.exe`, which `resolveCommand` is for. Kept
 * here so the argv a Windows run uses is written down in one place that a check
 * can read, rather than assembled inline where only a Windows machine would
 * exercise it.
 */
export function snapshotArgv() {
  return ['api', 'snapshot']
}

/** True when the given platform runs programs through a PowerShell probe. */
export function isWindows(platform = process.platform) {
  return platform === 'win32'
}