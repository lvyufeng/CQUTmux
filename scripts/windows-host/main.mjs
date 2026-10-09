// The assertions for `host/cqutmux-hook/platform.mjs`, run by
// `scripts/windows-host-check.sh`.
//
// Kept as a file rather than an inline `node -e` because the Windows pipe path
// is all backslashes, and getting them through bash's own escaping without a
// mismatch is more error-prone than reading them here.

import { resolveCommand, socketPath, snapshotArgv, isWindows } from '../../host/cqutmux-hook/platform.mjs'

let pass = 0
const ok = (condition, message) => {
  if (!condition) { console.log('FAIL  ' + message); process.exit(1) }
  pass++
  console.log('PASS  ' + message)
}

// 1. Windows resolution is a PowerShell Get-Command probe.
const win = resolveCommand('herdr', 'win32')
ok(win.shell === 'powershell', 'Windows resolution goes through powershell')
ok(win.argv.some(a => a.includes('Get-Command')), 'the Windows probe calls Get-Command')
ok(win.argv.some(a => a.includes('Get-Command herdr')), 'the program name is in the probe')
ok(win.argv.includes('-NoProfile'), 'the probe passes -NoProfile')
ok(win.argv.includes('-NonInteractive'), 'the probe passes -NonInteractive')
ok(win.presentWhen === 'non-empty-stdout', 'Windows presence is read from stdout')

// 2. POSIX resolution is command -v through sh.
const posix = resolveCommand('herdr', 'linux')
ok(posix.shell === 'sh', 'POSIX resolution goes through sh')
ok(posix.argv.join(' ').includes('command -v herdr'), 'the POSIX probe uses command -v')
ok(!posix.argv.join(' ').includes('powershell'), 'the POSIX probe never mentions powershell')

// 3. The socket path differs by platform, and Windows uses a named pipe.
const winSock = socketPath('C:\\Users\\alice', 'win32')
ok(winSock.startsWith('\\\\.\\pipe\\'), 'the Windows socket is a named pipe: ' + winSock)
ok(winSock.endsWith('herdr-alice'), 'the pipe name carries the account: ' + winSock)

const posixSock = socketPath('/home/alice', 'linux')
ok(posixSock === '/home/alice/.config/herdr/herdr.sock',
   'the POSIX socket path is the documented one: ' + posixSock)

// 4. Two accounts on one Windows machine get different pipes.
const bob = socketPath('C:\\Users\\bob', 'win32')
ok(winSock !== bob, 'two Windows accounts get different pipe names')

// The pipe *name* — everything after the last separator — has no separator in
// it. Checked on that segment rather than the whole path, which of course has
// separators in its `\\.\pipe\` prefix.
const pipeName = winSock.slice(winSock.lastIndexOf('\\') + 1)
ok(!pipeName.includes('/') && !pipeName.includes('\\'),
   'the pipe name has no path separator: ' + pipeName)

// A home with a space and a symbol must still sanitise, so a name cannot break
// out of the pipe namespace.
const odd = socketPath('C:\\Users\\a b!c', 'win32')
const oddName = odd.slice(odd.lastIndexOf('\\') + 1)
ok(!oddName.includes(' ') && !oddName.includes('!'), 'symbols are sanitised out of the pipe name: ' + oddName)

// A missing home must not produce an empty pipe name.
const none = socketPath('', 'win32')
ok(none.endsWith('herdr-default'), 'an empty home falls back to a default pipe name: ' + none)

// The snapshot arguments are the same on both platforms, so the platform branch
// is only about finding the program.
ok(JSON.stringify(snapshotArgv()) === '["api","snapshot"]',
   'the snapshot arguments are api snapshot: ' + JSON.stringify(snapshotArgv()))

// isWindows is the single predicate the rest of the code branches on.
ok(isWindows('win32') === true && isWindows('darwin') === false && isWindows('linux') === false,
   'isWindows agrees with the platform strings')

console.log('')
console.log('WINDOWS_HOST_PASS  (' + pass + ' checks)')