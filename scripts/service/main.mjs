// The assertions for `host/cqutmux-hook/service.mjs`, run by
// `scripts/service-check.sh`.
//
// Kept as a file rather than an inline `node -e` because the values under test
// are XML and systemd unit text, and getting those through bash's own escaping
// without a mismatch is more error-prone than reading them here.

import {
  SERVICE_ID,
  unitPlan,
  serviceArgv,
  xmlEscape,
  launchdPlist,
  systemdUnit,
  servicePlan,
} from '../../host/cqutmux-hook/service.mjs'

let pass = 0
const ok = (condition, message) => {
  if (!condition) { console.log('FAIL  ' + message); process.exit(1) }
  pass++
  console.log('PASS  ' + message)
}

// MARK: - Where the unit goes

const mac = unitPlan({ platform: 'darwin', home: '/Users/alice' })
ok(mac.kind === 'launchd', 'macOS uses launchd')
ok(mac.path === '/Users/alice/Library/LaunchAgents/dev.cqutmux.gateway.plist',
   'the macOS plist is a per-user LaunchAgent: ' + mac.path)
ok(mac.label === SERVICE_ID, 'the label is the one id')
// The filename and the label must agree, or `launchctl list <label>` reports a
// service whose file is named something else — a status that says "not found"
// about a file that is right there.
ok(mac.path.endsWith(`${SERVICE_ID}.plist`), 'the plist filename carries the same id')

const lin = unitPlan({ platform: 'linux', home: '/home/bob' })
ok(lin.kind === 'systemd', 'Linux uses systemd')
ok(lin.path === '/home/bob/.config/systemd/user/dev.cqutmux.gateway.service',
   'the Linux unit is a user unit: ' + lin.path)

// User-level on both platforms, never system-wide: the gateway uses the user's
// SSH keys, keychain and tmux sockets, and a root service would have none of
// them. This is the mistake that "works" and then cannot find the user's tmux.
ok(mac.path.includes('/Users/alice/') && !mac.path.includes('/Library/LaunchDaemons/'),
   'the macOS unit is a LaunchAgent, not a LaunchDaemon')
ok(lin.path.includes('/.config/systemd/user/') && !lin.path.includes('/etc/systemd/system/'),
   'the Linux unit is a user unit, not a system unit')

const win = unitPlan({ platform: 'win32', home: 'C:\\Users\\c' })
ok(win.kind === 'unsupported', 'Windows is reported unsupported rather than faked')

// MARK: - The command the service runs

const argv = serviceArgv({
  nodePath: '/usr/local/bin/node',
  scriptPath: '/opt/cqutmux/index.mjs',
  port: 24543,
  token: 'secret',
})
ok(argv.program === '/usr/local/bin/node', 'the service runs the resolved node, not a name')
ok(argv.args[0] === '/opt/cqutmux/index.mjs', 'the script path is absolute and first')
ok(argv.args[1] === 'serve', 'the subcommand is serve')
ok(argv.args.includes('--port') && argv.args.includes('24543'), 'the port is passed through')
ok(argv.args.includes('--token') && argv.args.includes('secret'), 'the token is passed through')

const bare = serviceArgv({ nodePath: '/n', scriptPath: '/s' })
ok(!bare.args.includes('--port') && !bare.args.includes('--token'),
   'no port or token means neither flag is written')

// MARK: - XML escaping

// An unescaped `&` or `<` in a token makes a plist `launchctl` refuses to
// parse — a service that silently never starts, which is the exact failure this
// feature exists to prevent. Ampersand has to be escaped first or the `&` in
// the entities the later replacements add would be doubled.
ok(xmlEscape('a&b') === 'a&amp;b', 'ampersand is escaped')
ok(xmlEscape('a<b') === 'a&lt;b', 'less-than is escaped')
ok(xmlEscape('a>b') === 'a&gt;b', 'greater-than is escaped')
ok(xmlEscape('a"b') === 'a&quot;b', 'double quote is escaped')
ok(xmlEscape("a'b") === 'a&apos;b', 'single quote is escaped')
ok(xmlEscape('&lt;') === '&amp;lt;', 'an existing entity is escaped, not left as markup')

// MARK: - The launchd plist

const plist = launchdPlist({ program: '/usr/bin/node', args: ['/s/index.mjs', 'serve'], logPath: '/h/.cqutmux/hook.log' })
ok(plist.startsWith('<?xml version="1.0"'), 'the plist is XML')
ok(plist.includes('<!DOCTYPE plist PUBLIC'), 'the plist declares its DOCTYPE')
ok(plist.includes('<key>Label</key>'), 'the plist has a Label')
ok(plist.includes(`<string>${SERVICE_ID}</string>`), 'the Label is the service id')
ok(plist.includes('<key>ProgramArguments</key>'), 'the plist has ProgramArguments')
ok(plist.includes('<string>/usr/bin/node</string>'), 'the program is an argument')
ok(plist.includes('<string>serve</string>'), 'the subcommand is an argument')
// RunAtLoad is what makes it start at login; without it the plist is registered
// and idle, which looks identical to an installed service until you reboot.
ok(/<key>RunAtLoad<\/key>\s*<true\/>/.test(plist), 'RunAtLoad is set, so it starts at login')
ok(/<key>KeepAlive<\/key>\s*<true\/>/.test(plist), 'KeepAlive restarts a gateway that dies')
ok(plist.includes('<string>/h/.cqutmux/hook.log</string>'), 'stdout goes to the gateway log')
ok((plist.match(/<key>StandardErrorPath<\/key>/g) || []).length === 1,
   'stderr goes to the same log, once')

// A token with markup in it survives into a parseable plist.
const tricky = launchdPlist({ program: '/n', args: ['serve', '--token', 'a&b<c'], logPath: '/l' })
ok(tricky.includes('a&amp;b&lt;c'), 'a token containing markup is escaped into the plist')
ok(!tricky.includes('a&b<c'), 'and never appears raw')

// MARK: - The systemd unit

const unit = systemdUnit({ program: '/usr/bin/node', args: ['/s/index.mjs', 'serve'], logPath: '/h/.cqutmux/hook.log' })
ok(unit.includes('[Unit]') && unit.includes('[Service]') && unit.includes('[Install]'),
   'the unit has the three sections systemd reads')
ok(unit.includes('WantedBy=default.target'), 'it is wanted by the user default target')
ok(unit.includes('Restart=on-failure'), 'it restarts on failure')
ok(unit.includes('ExecStart='), 'it has an ExecStart')
// Every path is quoted, including one with a space: systemd splits ExecStart on
// whitespace itself, so an unquoted `/Users/First Last` home becomes two
// arguments and the gateway is asked to serve a directory that does not exist.
ok(unit.includes('"/usr/bin/node"'), 'the program is quoted')
ok(unit.includes('"/s/index.mjs"'), 'each argument is quoted independently')

const spaced = systemdUnit({ program: '/usr/bin/node', args: ['/Users/First Last/serve me.mjs'], logPath: '/l' })
ok(spaced.includes('"/Users/First Last/serve me.mjs"'),
   'a path with a space stays one quoted argument')
ok(!/ExecStart=.*\n.*serve me/.test(spaced), 'the space does not split ExecStart across arguments')

// MARK: - The whole plan

const plan = servicePlan({
  platform: 'darwin',
  home: '/Users/alice',
  logPath: '/Users/alice/.cqutmux/hook.log',
  nodePath: '/usr/local/bin/node',
  scriptPath: '/opt/index.mjs',
  port: 24543,
  token: 't',
})
ok(plan.supported === true, 'macOS is supported')
ok(plan.content.includes('RunAtLoad'), 'the plan carries the file content')
ok(plan.load[0] === 'launchctl' && plan.load.includes('-w'), 'the plan can load it')
ok(plan.unload[0] === 'launchctl', 'the plan can unload it')
ok(plan.status[0] === 'launchctl' && plan.status.includes(SERVICE_ID),
   'the plan knows how to ask about it, by the same id')

const linPlan = servicePlan({ platform: 'linux', home: '/home/bob', logPath: '/l', nodePath: '/n', scriptPath: '/s' })
ok(linPlan.load.join(' ').includes('systemctl --user enable'),
   'the Linux plan enables the user unit')
ok(linPlan.status.join(' ').includes('is-active'), 'the Linux plan asks is-active')

const winPlan = servicePlan({ platform: 'win32', home: 'C:\\Users\\c', logPath: '/l', nodePath: '/n', scriptPath: '/s' })
ok(winPlan.supported === false, 'the Windows plan is explicitly unsupported, not silently empty')

console.log('')
console.log('SERVICE_PASS  (' + pass + ' checks)')