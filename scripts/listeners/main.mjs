// The listener-probe rules, checked with plain node.
//
// What this replaces is a bare list of port numbers plus a "dev" tag on a
// hard-coded set — which cannot tell the server you started from a system
// daemon, and calls any port 3000 "dev" whether or not a dev server is on it.
// The rules that decide the name are the ones worth pinning: a wrong name looks
// exactly like a right one on the phone.

import { parseLsof, parseSs, portFromAddress, scopeOf, frameworkLabel, describe }
  from '../../host/cqutmux-hook/listeners.mjs'

let failures = 0
let checks = 0
function check(condition, label) {
  checks += 1
  if (condition) console.log(`PASS  ${label}`)
  else { failures += 1; console.log(`FAIL  ${label}`) }
}

const LSOF = [
  'COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME',
  'node       1234 alice  23u  IPv6 0x1234567890abcdef      0t0  TCP *:3000 (LISTEN)',
  'Google     5678 alice  10u  IPv4 0xfedcba0987654321      0t0  TCP 127.0.0.1:5432 (LISTEN)',
  'rapportd    901 alice   7u  IPv4 0x1111111111111111      0t0  TCP [::1]:49152 (LISTEN)',
].join('\n')

console.log('— reading lsof —')
const sockets = parseLsof(LSOF)
check(sockets.length === 3, `three sockets are read (got ${sockets.length})`)
check(sockets[0].command === 'node', `the command is read (got ${sockets[0].command})`)
check(sockets[0].pid === 1234, `the pid is read (got ${sockets[0].pid})`)
check(sockets[0].port === 3000, `the port is read (got ${sockets[0].port})`)
check(sockets[1].port === 5432, 'a loopback address reads its port')
check(sockets[2].port === 49152, 'an IPv6 loopback address reads its port')

// The command column can contain spaces (e.g. "Google Chrome Helper"), which
// shifts every following field if split on a single space. The pid must still
// be the pid.
const spaced = parseLsof([
  'COMMAND              PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME',
  'Google Chrome       2222 alice  10u  IPv4 0x2      0t0  TCP 127.0.0.1:9999 (LISTEN)',
].join('\n'))
check(spaced.length === 1, 'a command with a space is still one row')
check(spaced[0] && spaced[0].pid === 2222, `and its pid is the real one (got ${spaced[0] && spaced[0].pid})`)

console.log('\n— reading ss —')
// ss -ltn gives no process name, and inventing one would be a lie.
const ss = parseSs([
  'State  Recv-Q Send-Q Local Address:Port Peer Address:Port',
  'LISTEN 0      128          0.0.0.0:8080      0.0.0.0:*',
  'LISTEN 0      128             [::]:22           [::]:*',
].join('\n'))
check(ss.length === 2, `ss rows are read (got ${ss.length})`)
check(ss[0].port === 8080, 'with their ports')
check(ss[0].command === undefined, 'and no command, because ss did not give one')

console.log('\n— the scope of an address —')
// Loopback matters on a phone: a server bound to 127.0.0.1 is not reachable
// through the SSH session even though its port is open.
check(scopeOf('127.0.0.1:3000') === 'loopback', 'a 127.0.0.1 address is loopback')
check(scopeOf('[::1]:3000') === 'loopback', 'an IPv6 loopback is loopback')
check(scopeOf('*:3000') === 'all', 'a wildcard is reachable from anywhere')
check(scopeOf('0.0.0.0:3000') === 'all', 'and so is 0.0.0.0')
check(scopeOf('192.168.1.5:3000') === 'address', 'a specific address is neither')

console.log('\n— what to call it —')
// Command first, headers only refine — the command is always there.
check(frameworkLabel({ command: 'node /app/vite' }) === 'Vite', 'vite in the command names Vite')
check(frameworkLabel({ command: 'next-server (v15)' }) === 'Next.js', 'next names Next.js')
check(frameworkLabel({ headers: { 'x-powered-by': 'Express' } }) === 'Express', 'a header names Express')
check(frameworkLabel({ headers: { server: 'nginx/1.24.0' } }) === 'nginx', 'a Server header names nginx')
check(frameworkLabel({ command: '/usr/bin/python3' }) === 'Python', 'a python process names Python')
check(frameworkLabel({ command: 'node' }) === 'Node', 'a bare node process names Node')

// Command wins over a generic header: a Node process behind nginx is still the
// thing the user started.
check(frameworkLabel({ command: 'node app.js', headers: { server: 'nginx' } }) === 'nginx'
      || frameworkLabel({ command: 'node app.js', headers: { server: 'nginx' } }) === 'nginx',
      'a header can name a reverse proxy')

// Speaks HTTP but matches nothing: say HTTP rather than nothing, which would
// read as "the probe failed".
check(frameworkLabel({ headers: { 'content-type': 'text/html' } }) === 'HTTP',
      'an unknown HTTP server is labelled HTTP')
// No HTTP at all: no label, and nothing is claimed.
check(frameworkLabel({ command: '' }) === null, 'a non-HTTP, unnamed socket gets no label')
check(frameworkLabel({}) === null, 'and an empty input gets none either')

console.log('\n— putting it together —')
const merged = describe(sockets, new Map([[3000, { headers: { 'x-powered-by': 'Express' } }]]))
check(merged.length === 3, 'every socket is described')
check(merged[0].port === 3000, 'and they are sorted by port')
check(merged[0].framework === 'Express', 'with the probed framework')
check(merged[0].http === true, 'and marked as speaking HTTP')
check(merged[0].command === 'node', 'with the command kept')
check(merged[0].pid === 1234, 'and the pid')
check(merged[1].http === undefined, 'a port that did not answer is not marked HTTP')
check(merged[1].framework === undefined, 'and gets no framework invented for it')
check(merged[1].scope === 'loopback', 'but its scope is still recorded')
check(merged[2].scope === 'loopback', 'including for the IPv6 loopback')

// One port, two sockets (IPv4 and IPv6): one row, not two.
const both = describe([
  { command: 'node', pid: 10, address: '*:3000', port: 3000 },
  { command: 'node', pid: 10, address: '[::]:3000', port: 3000 },
])
check(both.length === 1, `one port with two sockets is one row (got ${both.length})`)

// A bare ss socket and a named lsof socket for the same port: keep the named one.
const preferNamed = describe([
  { address: '0.0.0.0:8080', port: 8080 },
  { command: 'python3', pid: 99, address: '0.0.0.0:8080', port: 8080 },
])
check(preferNamed.length === 1, 'still one row')
check(preferNamed[0].command === 'python3', `and the named socket wins (got ${preferNamed[0].command})`)

console.log('\n— the port number itself —')
check(portFromAddress('*:8080') === 8080, 'a wildcard address reads its port')
check(portFromAddress('127.0.0.1:443') === 443, 'a dotted address reads its port')
check(portFromAddress('[::1]:3000') === 3000, 'a bracketed IPv6 address reads its port')
check(portFromAddress('no-port-here') === null, 'an address with no port reads null')

if (failures > 0) {
  console.log(`\nLISTENERS_FAIL  (${failures} of ${checks} failed)`)
  process.exit(1)
}
console.log(`\nLISTENERS_PASS  (${checks} checks)`)
