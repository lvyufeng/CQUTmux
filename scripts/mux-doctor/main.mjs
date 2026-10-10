// The assertions for `host/cqutmux-hook/doctor-mux.mjs`, run by
// `scripts/mux-doctor-check.sh`.
//
// Kept as a file rather than an inline `node -e` because the values under test
// are PATH strings and shell pipelines, and getting those through bash's own
// escaping without a mismatch is more error-prone than reading them here.

import {
  PROBE_PATH_DIRS,
  MUX_NAMES,
  probeScript,
  parseProbe,
  versionToken,
  diagnose,
  formatReport,
  isProblem,
} from '../../host/cqutmux-hook/doctor-mux.mjs'

let pass = 0
const ok = (condition, message) => {
  if (!condition) { console.log('FAIL  ' + message); process.exit(1) }
  pass++
  console.log('PASS  ' + message)
}

// MARK: - The preflight reproduces the picker's PATH

// The PATH prepend is the whole diagnosis. On a login shell a conda tmux comes
// *last*; here it comes after /usr/bin, so the preflight resolves a different
// binary than the user's shell — which is the class of bug this exists to name.
const script = probeScript()
ok(PROBE_PATH_DIRS[0] === '$HOME/.local/bin', 'the probe PATH starts with ~/.local/bin')
const homeIdx = script.indexOf('$HOME/.local/bin')
const pathIdx = script.indexOf(':$PATH')
ok(homeIdx >= 0 && pathIdx > homeIdx, 'the probe prepends to PATH rather than replacing it')
ok(script.indexOf('/usr/bin') < script.indexOf(':$PATH'),
   '/usr/bin comes before the user PATH, as the picker does')
ok(script.includes('export PATH='), 'the probe exports the PATH before probing')

// MARK: - The duplicate probe is one that actually runs

// `command -v -a` is not a thing: bash's `command` rejects `-a` and /bin/sh is
// bash on macOS, so a probe built on it answers nothing and reads as "not
// installed". Pinning its absence is the regression guard for that whole error.
ok(!script.includes('command -v -a'), 'the probe does not use the non-existent `command -v -a`')
ok(script.includes('which -a'), 'the probe enumerates copies with `which -a`')
ok(script.includes("grep '^/'"),
   'the probe keeps only absolute paths, so a "not found" line is not read as a binary')
// Order matters: the first copy is the one the picker runs, so de-duplication
// must keep first-seen order rather than sort.
ok(script.includes('awk \'!seen[$0]++\''), 'duplicate paths are removed without reordering')

// MARK: - versionToken compares builds, not banners

// `tmux -V` prints `tmux 3.5a`; tmux's own `#{version}` prints `3.5a`. Compared
// raw they are a permanent mismatch — a warning on every healthy host, which is
// the one a reader learns to skip.
ok(versionToken('tmux 3.5a') === '3.5a', 'the program name is stripped from a version')
ok(versionToken('zellij 0.40.1') === '0.40.1', 'zellij versions normalise too')
ok(versionToken('3.5a') === '3.5a', 'a bare version is left alone')
ok(versionToken('') === null && versionToken(null) === null, 'a missing version is null, not a string')
ok(versionToken('tmux 3.5a') === versionToken('3.5a'),
   'the two spellings of one build compare equal')

// MARK: - Reading the probe back

const parsed = parseProbe([
  'cqutmux-bin tmux /usr/bin/tmux',
  'cqutmux-bin tmux /opt/homebrew/bin/tmux',
  'cqutmux-ver tmux tmux 3.5a',
  'cqutmux-bin zellij /usr/bin/zellij',
].join('\n'))
ok(parsed.copies.tmux.length === 2, 'both copies of tmux are read')
ok(parsed.copies.tmux[0] === '/usr/bin/tmux', 'copies keep the probe order')
ok(parsed.versions.tmux === 'tmux 3.5a', 'the version line is read')
ok(parsed.copies.zellij.length === 1, 'a name with one copy reads as one')

// A shell's own noise — an rc-file warning, a banner — is not a binary. Folding
// it into the path list would invent a program that does not exist.
const noisy = parseProbe('bash: warning: setlocale: LC_ALL: cannot change locale\n' +
  'cqutmux-bin tmux /usr/bin/tmux\n' +
  'bash: /etc/profile: line 1: something')
ok(noisy.copies.tmux.length === 1, 'unprefixed shell noise is ignored')
ok(noisy.copies.bash === undefined, 'a warning is not recorded as a binary')
ok(parseProbe('').copies.tmux === undefined, 'empty output yields no copies')

// MARK: - The diagnosis

const absent = diagnose({ name: 'tmux', copies: [] })
ok(absent.status === 'absent', 'no copies is "absent", which is not a problem')
ok(!isProblem(absent), 'a missing multiplexer does not fail doctor')

const daemonMiss = diagnose({
  name: 'tmux',
  copies: ['/usr/local/bin/tmux'],
  version: '3.5a',
  daemonPath: null,
})
ok(daemonMiss.status === 'daemon-cannot-find',
   'a binary the picker finds and the daemon does not is its own status')
ok(isProblem(daemonMiss), 'that disagreement fails doctor')
ok(daemonMiss.fix.includes('/usr/local/bin'),
   'the fix names the directory the daemon is missing')

const dup = diagnose({
  name: 'tmux',
  copies: ['/opt/homebrew/bin/tmux', '/usr/bin/tmux'],
  version: '3.5a',
  daemonPath: '/opt/homebrew/bin/tmux',
})
ok(dup.status === 'duplicate', 'two distinct installs is a duplicate')
ok(isProblem(dup), 'a duplicate fails doctor')
ok(dup.fix.includes('/opt/homebrew/bin/tmux'),
   'the duplicate fix symlinks over the picker\'s own copy')

// Two symlinks to one binary are one install spelled twice. Warning about them
// would train the reader to ignore the warning, which is worse than silence.
const same = diagnose({
  name: 'tmux',
  copies: ['/usr/local/bin/tmux', '/usr/local/bin/tmux'],
  version: '3.5a',
  daemonPath: '/usr/local/bin/tmux',
})
ok(same.status === 'ok', 'the same path twice is not a duplicate')

const mismatch = diagnose({
  name: 'tmux',
  copies: ['/opt/homebrew/bin/tmux'],
  version: '3.5a',
  daemonPath: '/opt/homebrew/bin/tmux',
  serverVersion: '3.4',
})
ok(mismatch.status === 'version-mismatch', 'a server on another build is a mismatch')
ok(isProblem(mismatch), 'a version split fails doctor')
ok(mismatch.note.includes('3.5a') && mismatch.note.includes('3.4'),
   'both versions are named, so the reader can see which is which')

const match = diagnose({
  name: 'tmux',
  copies: ['/opt/homebrew/bin/tmux'],
  version: '3.5a',
  daemonPath: '/opt/homebrew/bin/tmux',
  serverVersion: '3.5a',
})
ok(match.status === 'ok', 'a matching server is healthy')

// A server that is up but refused to name its version is not the same fact as
// no server, and only one of them is a clean bill of health.
const unknown = diagnose({
  name: 'tmux',
  copies: ['/opt/homebrew/bin/tmux'],
  version: '3.5a',
  daemonPath: '/opt/homebrew/bin/tmux',
  serverUnknown: true,
})
ok(unknown.status === 'server-unknown', 'an unreadable server version is reported')
ok(!isProblem(unknown), 'but it is a caveat, not a failure')

// MARK: - The report

const report = formatReport([absent, absent, absent]).join('\n')
ok(report.includes('none installed'), 'with nothing installed the report says so plainly')
ok(!report.includes('tmux'), 'and does not list a multiplexer it did not find')

const mixed = formatReport([
  diagnose({ name: 'tmux', copies: ['/usr/bin/tmux'], version: '3.5a', daemonPath: '/usr/bin/tmux' }),
  diagnose({ name: 'zellij', copies: [] }),
  daemonMiss,
]).join('\n')
ok(mixed.includes('Multiplexers'), 'the section is titled')
ok(mixed.includes('ok   tmux'), 'a healthy multiplexer is an ok line')
ok(!mixed.includes('zellij'), 'an absent multiplexer is left out of the report')
ok(mixed.includes('warn'), 'a disagreement is a warn line')

// The report is for a human reading a terminal; an em dash or an arrow is fine,
// but a raw newline inside a note would break the section's shape.
ok(!formatReport([dup]).some(line => line.includes('\n')), 'no rendered line contains a newline')

// MARK: - The names probed

ok(JSON.stringify(MUX_NAMES) === '["tmux","zellij","herdr"]',
   'the three multiplexers the picker can offer are probed')
ok(probeScript(['tmux']).includes('cqutmux-bin tmux') && !probeScript(['tmux']).includes('zellij'),
   'the probed set is the one asked for')

console.log('')
console.log('MUX_DOCTOR_PASS  (' + pass + ' checks)')