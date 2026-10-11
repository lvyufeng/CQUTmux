// The assertions for `host/cqutmux-hook/serve-sim.mjs`, run by
// `scripts/serve-sim-check.sh`.
//
// Each of the three triggers Moshi's documentation names is asserted on its own
// — a rule that only answers "is this a preview?" cannot be told apart from one
// that fires for the wrong reason, so the *which* and the *port* and the *name*
// are checked, not just the boolean. The near-misses are asserted too, because
// `serve-simulator` and `restart-serve-sim-old` are the strings a substring
// match would wrongly classify, and a wrong "Simulator Preview" label is the one
// failure a user cannot see through.

import {
  SERVE_SIM_TOKEN,
  PREVIEW_MARKER_HEADER,
  PREVIEW_MARKER_TOKEN,
  PREVIEW_LABEL,
  commandLineIsServeSim,
  stateDir,
  parseStateFile,
  parseStateDirectory,
  pageCarriesPreviewMarker,
  triggersFor,
  classify,
  classifyListeners,
} from '../../host/cqutmux-hook/serve-sim.mjs'

let checks = 0
let failures = 0

function check(condition, label) {
  checks += 1
  if (condition) {
    console.log(`PASS  ${label}`)
  } else {
    failures += 1
    console.log(`FAIL  ${label}`)
  }
}

// MARK: - Trigger 1: the process / command line

check(commandLineIsServeSim('serve-sim'), 'a bare `serve-sim` matches')
check(commandLineIsServeSim('/usr/local/bin/serve-sim'), 'a path ending in the token matches')
check(commandLineIsServeSim('node serve-sim --port 8080'), 'the token as an argument matches')
check(commandLineIsServeSim('/bin/sh -c "serve-sim --port 8080"'), 'the token inside a shell line matches')
check(commandLineIsServeSim('serve-sim\n'), 'a trailing newline does not hide the token')
// The near-misses. A substring test passes all of these and mislabels the port,
// which is the failure this rule exists to avoid.
check(!commandLineIsServeSim('serve-simulator'), '`serve-simulator` is not the token')
check(!commandLineIsServeSim('/opt/restart-serve-sim-old/serve'), 'a hyphen-joined near-miss is not the token')
check(!commandLineIsServeSim('node server.js'), 'an unrelated node server does not match')
check(!commandLineIsServeSim(''), 'an empty command line does not match')
check(!commandLineIsServeSim(null), 'a missing command line does not match')

// MARK: - Trigger 2: the state file under $TMPDIR/serve-sim/

check(stateDir('/var/folders/abc/T') === '/var/folders/abc/T/serve-sim',
  'the state dir is $TMPDIR/serve-sim')
check(stateDir('/tmp/') === '/tmp/serve-sim', 'a trailing slash on the temp dir is not doubled')

const json = parseStateFile(JSON.stringify({ port: 8080, deviceName: 'iPhone 15 Pro' }))
check(json && json.port === 8080, 'a JSON state file yields its port')
check(json && json.deviceName === 'iPhone 15 Pro', 'and its device name')

const nested = parseStateFile(JSON.stringify({ port: '8081', device: { name: 'iPad Air' } }))
check(nested && nested.port === 8081, 'a string port is read as a number')
check(nested && nested.deviceName === 'iPad Air', 'a nested device object yields the name')

const bare = parseStateFile('5173\n')
check(bare && bare.port === 5173, 'a bare port number is a state file')
check(bare && bare.deviceName === null, 'and carries no name to invent')

const lines = parseStateFile('device=iPhone 16\nport=9000\n')
check(lines && lines.port === 9000, 'a key=value state file yields its port')
check(lines && lines.deviceName === 'iPhone 16', 'and its device line')

const url = parseStateFile(JSON.stringify({ url: 'http://127.0.0.1:7000/preview' }))
check(url && url.port === 7000, 'a URL form yields the port it contains')

check(parseStateFile('no port here') === null, 'a state file with no port is not a preview')
check(parseStateFile('') === null, 'an empty state file is not a preview')

const dir = parseStateDirectory([
  { name: 'stale.json', content: JSON.stringify({ port: 1234, deviceName: 'Old' }), mtime: 100 },
  { name: 'current.json', content: JSON.stringify({ port: 8080, deviceName: 'New' }), mtime: 200 },
])
check(dir && dir.port === 8080, 'the newest state file wins over a stale one')
check(dir && dir.deviceName === 'New', 'and brings its device name')
check(dir && dir.file === 'current.json', 'and names the file it came from')

const unparseable = parseStateDirectory([
  { name: 'junk', content: 'not a port', mtime: 999 },
  { name: 'ok', content: '9999', mtime: 1 },
])
check(unparseable && unparseable.port === 9999,
  'an unparseable file is skipped even when it is newest')

check(parseStateDirectory([]) === null, 'an empty directory is no preview')
check(parseStateDirectory(null) === null, 'a missing directory is no preview')

// MARK: - Trigger 3: the page's preview marker

check(pageCarriesPreviewMarker({ headers: { [PREVIEW_MARKER_HEADER]: '1' } }),
  'the marker header classifies the page')
check(pageCarriesPreviewMarker({ headers: { [PREVIEW_MARKER_HEADER]: 'true' } }),
  'the header is case-insensitive in value')
check(pageCarriesPreviewMarker({ body: `<meta name="generator" content="${PREVIEW_MARKER_TOKEN}">` }),
  'the marker token in the body classifies the page')
check(!pageCarriesPreviewMarker({ headers: { [PREVIEW_MARKER_HEADER]: '0' } }),
  'an explicit false header does not classify')
check(!pageCarriesPreviewMarker({ headers: {}, body: '<html>hello</html>' }),
  'an ordinary page is not a preview')
check(!pageCarriesPreviewMarker({}), 'a page with nothing is not a preview')

// A header whose case differs must still be found: HTTP headers are not
// case-sensitive, and a server that sends `X-Serve-Sim-Preview` is the same
// trigger.
check(pageCarriesPreviewMarker({ headers: { 'X-Serve-Sim-Preview': 'yes' } }),
  'the header name is matched case-insensitively')

// MARK: - Classification

const all = classify({
  commandLine: 'node /usr/local/bin/serve-sim --port 8080',
  stateFile: { port: 8080, deviceName: 'iPhone 15' },
  marker: true,
})
check(all.simulatorPreview === true, 'a fully-matched preview classifies')
check(all.port === 8080, 'the classification carries the port')
check(all.deviceName === 'iPhone 15', 'and the device name')
check(all.triggers.join(',') === 'process,state-file,marker',
  'all three documented triggers are recorded')

const none = classify({ commandLine: 'node server.js', stateFile: null, marker: false })
check(none.simulatorPreview === false, 'nothing matched means not a preview')
check(none.port === null && none.deviceName === null, 'and no port or name to show')
check(none.triggers.length === 0, 'and no triggers')

const processOnly = classify({ commandLine: 'serve-sim' })
check(processOnly.simulatorPreview === true, 'the process trigger alone classifies')
check(processOnly.port === null, 'a process-only match has no port of its own')

// The state file's port outranks the process's, because that is the port
// serve-sim actually bound.
const stateWins = classify({ commandLine: 'serve-sim', stateFile: { port: 6500 } })
check(stateWins.port === 6500, 'the state file supplies the port when both fire')

// MARK: - The no-duplicate rule

// The preview's port is already in the listener list. It must be *annotated*,
// not added again: one row, labelled, carrying every trigger.
const listed = classifyListeners(
  [
    { port: 8080, command: 'serve-sim', address: '127.0.0.1:8080', scope: 'loopback' },
    { port: 3000, command: 'node', address: '*:3000', scope: 'all' },
  ],
  { stateFile: { port: 8080, deviceName: 'iPhone 15' }, markerPorts: new Set([8080]) },
)
check(listed.listeners.length === 2, 'an already-listed preview adds no row')
const previewRow = listed.listeners.find(l => l.port === 8080)
check(previewRow.simulatorPreview === true, 'the row is classified as a preview')
check(previewRow.label === PREVIEW_LABEL, 'and carries the "Simulator Preview" label')
check(previewRow.deviceName === 'iPhone 15', 'and the device name from the state file')
check(previewRow.triggers.join(',') === 'process,state-file,marker',
  'and every trigger that fired for it')
check(previewRow.triggers.length === 3, 'with no trigger counted twice')
const plainRow = listed.listeners.find(l => l.port === 3000)
check(!plainRow.simulatorPreview, 'an unrelated server is left unclassified')
check(plainRow.label === undefined, 'and gets no label it did not earn')

// The port appears exactly once: that is the rule the doc calls "never appears
// twice in the web server list", asserted as a count rather than trusted.
check(listed.listeners.filter(l => l.port === 8080).length === 1,
  'the preview port appears exactly once')
check(listed.preview && listed.preview.port === 8080, 'the result names the preview')

// The preview's port is *not* in the listener list (loopback bind the scan
// missed). It is added once so the preview is still visible — and again, once.
const added = classifyListeners(
  [{ port: 3000, command: 'node', address: '*:3000', scope: 'all' }],
  { stateFile: { port: 7000, deviceName: 'iPad' } },
)
check(added.listeners.length === 2, 'a preview the scan missed is added as one row')
const addedRow = added.listeners.find(l => l.port === 7000)
check(addedRow && addedRow.simulatorPreview === true, 'and it is classified')
check(addedRow && addedRow.scope === 'loopback', 'and its scope is loopback, which serve-sim binds')
check(addedRow && addedRow.deviceName === 'iPad', 'and it carries the device name')
check(added.listeners.filter(l => l.port === 7000).length === 1, 'and it appears exactly once')

// A marker-only preview — no process name, no state file — is still classified,
// and still has no device name, because the doc ties the name to the state file.
const markerOnly = classifyListeners(
  [{ port: 5100, command: 'node', address: '*:5100', scope: 'all' }],
  { markerPorts: new Set([5100]) },
)
const markerRow = markerOnly.listeners.find(l => l.port === 5100)
check(markerRow.simulatorPreview === true, 'a marker-only preview is classified')
check(markerRow.deviceName === undefined, 'and borrows no device name it was not given')
check(markerRow.triggers.join(',') === 'marker', 'and records only the marker trigger')

// A state file with no port cannot classify a listener: the port is the trigger.
const noPort = classifyListeners(
  [{ port: 8080, command: 'serve-sim', address: '127.0.0.1:8080', scope: 'loopback' }],
  { stateFile: { port: null, deviceName: 'X' } },
)
check(noPort.listeners[0].simulatorPreview === true,
  'the process trigger still classifies when the state file has no port')
check(noPort.listeners.length === 1, 'and adds no row without a port to add')

// MARK: - The constants the app reads

check(PREVIEW_LABEL === 'Simulator Preview', 'the label is the documented one')
check(SERVE_SIM_TOKEN === 'serve-sim', 'the process token is the documented one')

if (failures > 0) {
  console.log(`\nSERVE_SIM_FAIL  (${failures} of ${checks} failed)`)
  process.exit(1)
}
console.log(`\nSERVE_SIM_PASS  (${checks} checks)`)