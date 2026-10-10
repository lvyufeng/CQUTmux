// The terminal-context probe rules, checked with plain node.
//
// The probe answers "which multiplexer, session and pane is this shell in?" and
// is run by prompts and status lines that trust it silently. A wrong answer is
// not an error — it is valid JSON naming the wrong pane — so the precedence and
// the parsing are asserted here.

import { detectContext, sessionIndexFromTmux, contextPayload }
  from '../../host/cqutmux-hook/context.mjs'

let failures = 0
let checks = 0
function check(condition, label) {
  checks += 1
  if (condition) console.log(`PASS  ${label}`)
  else { failures += 1; console.log(`FAIL  ${label}`) }
}

console.log('— which multiplexer —')
check(detectContext({ TMUX: '/tmp/t,123,0', TMUX_PANE: '%1' }).kind === 'tmux', 'TMUX means tmux')
check(detectContext({ ZELLIJ: 'work' }).kind === 'zellij', 'ZELLIJ means zellij')
check(detectContext({ ZELLIJ_PANE_ID: '4' }).kind === 'zellij', 'a pane id alone is enough for zellij')
check(detectContext({ HERDR_ENV: '/tmp/h.sock' }).kind === 'herdr', 'HERDR_ENV means herdr')
check(detectContext({}).kind === null, 'nothing set means no multiplexer')
check(detectContext({ PATH: '/usr/bin', HOME: '/root' }).kind === null, 'and an unrelated environment is not mistaken for one')

console.log('\n— the innermost session wins —')
// zellij can run inside a tmux pane, and the user is typing into the inner one.
// Reporting the outer frame would name the wrong pane, which looks like a
// correct answer.
const nested = detectContext({ TMUX: '/tmp/t,1,0', TMUX_PANE: '%1', ZELLIJ: 'inner', ZELLIJ_PANE_ID: '9' })
check(nested.kind === 'zellij', 'a zellij inside tmux reports zellij')
check(nested.pane === '9', 'and the zellij pane, not the tmux one')
check(nested.session === 'inner', 'and the zellij session')

console.log('\n— the ids that name the place —')
check(detectContext({ TMUX_PANE: '%3' }).pane === '%3', 'the tmux pane id is read')
check(detectContext({ ZELLIJ_PANE_ID: '7' }).pane === '7', 'the zellij pane id is read')
check(detectContext({ HERDR_PANE: 'p-2', HERDR_ENV: '/tmp/h' }).pane === 'p-2', 'the herdr pane id is read')
check(detectContext({ HERDR_SESSION: 'main', HERDR_ENV: '/tmp/h' }).session === 'main', 'a herdr session name is preferred over the socket')

console.log('\n— reading $TMUX —')
// $TMUX is `socket,server_pid,session_index`. The index is not the name.
check(sessionIndexFromTmux('/private/tmp/tmux-501/default,12345,2') === '2', 'the session index is read')
check(sessionIndexFromTmux('/tmp/t,1,') === null, 'an empty index is null, not an empty string')
check(sessionIndexFromTmux('/tmp/t,1') === null, 'a truncated $TMUX is null')
check(sessionIndexFromTmux(undefined) === null, 'an unset $TMUX is null')
check(sessionIndexFromTmux('garbage') === null, 'and so is one with no commas')
// The socket path can contain commas in principle; the index is still last.
check(sessionIndexFromTmux(',,7') === '7', 'the index is the field after the second comma')

console.log('\n— what gets printed —')
const payload = contextPayload(detectContext({ TMUX_PANE: '%1' }), '/home/me/repo')
check(Object.keys(payload).sort().join(',') === 'cwd,kind,pane,session',
      `the payload has exactly kind/session/pane/cwd (got ${Object.keys(payload).sort().join(',')})`)
check(payload.cwd === '/home/me/repo', 'with the shell\'s own working directory')

// Every shape is JSON-serialisable and round-trips — a prompt parsing it must
// never get a value that breaks its parser.
for (const env of [{}, { TMUX: '/t,1,0', TMUX_PANE: '%1' }, { ZELLIJ: 'w', ZELLIJ_PANE_ID: '2' },
                   { HERDR_ENV: '/h', HERDR_PANE: 'p' }]) {
  const json = JSON.stringify(contextPayload(detectContext(env), '/x'))
  const back = JSON.parse(json)
  check(typeof back.kind === 'string' || back.kind === null, `round-trips for ${JSON.stringify(env)}`)
  check(back.cwd === '/x', 'and keeps the cwd')
}

// A shell with no multiplexer still prints a full object — a prompt that reads
// `.kind` must get null, not a missing key.
const bare = contextPayload(detectContext({}), '/x')
check('kind' in bare && bare.kind === null, 'no multiplexer is a null kind, not a missing key')
check('session' in bare && bare.session === null, 'and null session/pane')
check('pane' in bare && bare.pane === null, 'pane too')

if (failures > 0) {
  console.log(`\nCONTEXT_FAIL  (${failures} of ${checks} failed)`)
  process.exit(1)
}
console.log(`\nCONTEXT_PASS  (${checks} checks)`)
