// The assertions for `host/cqutmux-hook/tmux-defaults.mjs`, run by
// `scripts/tmux-defaults-check.sh`.
//
// Kept as a file rather than an inline `node -e` because the values under test
// are tmux config text and the point of half of these is that a specific piece
// of it survives untouched — easier to read as literals here than to thread
// through bash's quoting.

let failures = 0
let checks = 0

function check(condition, label) {
  checks++
  if (condition) console.log(`PASS  ${label}`)
  else {
    failures++
    console.log(`FAIL  ${label}`)
  }
}

const {
  BEGIN, END, DEFAULTS, parseOptions, inspect, installed, strip, apply,
} = await import('../../host/cqutmux-hook/tmux-defaults.mjs')

// MARK: - The recommended set

// Four settings, and each names the option we look for when deciding whether
// the user already has it. `pane-base-index` must be written with `setw`, not
// `set`: tmux accepts `set -g pane-base-index 1` and then ignores it, which is
// the silent miss this feature exists to remove.
check(DEFAULTS.length === 4, 'four settings are recommended')
check(DEFAULTS.find(d => d.option === 'history-limit').line === 'set -g history-limit 100000',
      'history-limit is 100000, the Moshi number')
check(DEFAULTS.find(d => d.option === 'mouse').line === 'set -g mouse on', 'mouse is on')
check(DEFAULTS.find(d => d.option === 'base-index').line === 'set -g base-index 1', 'base-index is 1')
check(DEFAULTS.find(d => d.option === 'pane-base-index').line === 'setw -g pane-base-index 1',
      'pane-base-index uses setw — set would be accepted and do nothing')

// MARK: - Parsing a config

// The four spellings tmux accepts for "set an option".
const spellings = [
  'set -g mouse on',
  'set-option -g mouse on',
  'setw -g base-index 1',
  'set-window-option -g base-index 1',
]
for (const line of spellings) {
  const found = parseOptions(line)
  check(found.length === 1, `parsed one command from: ${line}`)
}

// `-t` takes a target as a *separate* argument; without skipping it the option
// name would be read as the target and the setting reported absent.
const targeted = parseOptions('setw -t 0:1 pane-base-index 1')
check(targeted.length === 1 && targeted[0].option === 'pane-base-index',
      'a `-t` target is skipped, not mistaken for the option name')

// Whitespace variants are the same setting.
check(parseOptions('set -g   mouse   on')[0].option === 'mouse', 'extra whitespace is tolerated')

// A comment, an unrelated option and a blank line.
check(parseOptions('# set -g mouse on').length === 0, 'a commented-out setting is not a setting')
check(parseOptions('').length === 0, 'an empty file has no settings')
check(parseOptions('bind-key r source-file ~/.tmux.conf').length === 0, 'a non-set command is ignored')

// MARK: - It must not touch the client-marker line

// `set-option -ga update-environment " CQUTMUX_CLIENT"` is a different option
// written by a different feature, and this module must leave it alone. It is
// not one of the four, so it is dropped by the option-name filter rather than
// special-cased — which is the robust way for it to stay dropped.
const clientLine = 'set-option -ga update-environment " CQUTMUX_CLIENT"'
const clientOptions = parseOptions(clientLine)
check(clientOptions.length === 1 && clientOptions[0].option === 'update-environment',
      'the update-environment line parses as its own option, not as one of ours')
// A semicolon inside a quoted value is not a command separator, so a value that
// merely *reads* like a setting is not picked up.
check(parseOptions('set -g status-left "a; set -g mouse on"').every(o => o.option !== 'mouse'),
      "a setting-looking value inside a quoted `;` is not read as a setting")

// MARK: - inspect reports presence, not value

const empty = inspect('')
check(empty.length === 4 && empty.every(r => !r.present), 'an empty config has none of the four')
check(empty.find(r => r.option === 'mouse').recommended === 'set -g mouse on',
      'a missing setting still reports the line we would write')

const partial = inspect('set -g mouse on\n')
check(partial.find(r => r.option === 'mouse').present, 'a present setting reports present')
check(partial.find(r => r.option === 'mouse').matchesRecommended, 'and exact matches say so')
check(!partial.find(r => r.option === 'base-index').present, 'an absent one reports absent')

// A different value is present, and reported as *not* matching — the report is
// how the user sees their value was respected rather than overwritten.
const own = inspect('set -g history-limit 5000\n')
const hist = own.find(r => r.option === 'history-limit')
check(hist.present, "the user's own value counts as present")
check(!hist.matchesRecommended, 'and is not claimed to match the recommendation')
check(hist.line === 'set -g history-limit 5000', 'the report shows the line the user wrote')

// MARK: - Applying

const applied = apply('')
check(applied.includes(BEGIN) && applied.includes(END), 'an empty config gets a guarded block')
check(applied.split(BEGIN).length - 1 === 1, 'exactly one block')
check(!applied.startsWith('\n'), 'an empty config gets no leading blank line')
check(DEFAULTS.every(d => applied.includes(d.line)), 'all four settings are written')

// Onto a file with the user's own content: it stays, ours goes after it.
const existing = 'set -g status-bg colour235\n'
const onto = apply(existing)
check(onto.startsWith(existing), "the user's own line is kept, first")
check(onto.includes(BEGIN), 'the block is added')

// Applying twice changes nothing: the failure being designed out is a second
// block, which would set each option twice with the last winning.
const twice = apply(onto)
check(twice === onto, 'applying twice is idempotent')
check(twice.split(BEGIN).length - 1 === 1, 'still exactly one block after two applications')

// A setting the user already has is not written into the block. Their value
// wins; they are not fought.
const withMouse = apply('set -g mouse on\n')
check(withMouse.includes('set -g mouse on'), "the user's mouse line is there")
check(!withMouse.includes('\nset -g mouse on\n'), 'and is not duplicated inside the block')
check(withMouse.split('set -g mouse on').length - 1 === 1, 'mouse appears exactly once')
check(withMouse.includes('set -g base-index 1'), 'the settings still missing are still written')

// Every setting already present means nothing is written at all.
const complete = DEFAULTS.map(d => d.line).join('\n') + '\n'
check(apply(complete) === complete, 'a config that already has all four is left byte-for-byte')

// The client-marker line survives an apply untouched, and is not absorbed.
const withClient = apply(`set -g status-left "x"\n${clientLine}\n`)
check(withClient.includes(clientLine), 'the update-environment line is left intact')
check(withClient.split('update-environment').length - 1 === 1, 'and is not duplicated')

// MARK: - Stripping

const stripped = strip(onto)
check(stripped.removed, 'strip reports it removed a block')
check(!stripped.text.includes(BEGIN), 'the block is gone')
check(!stripped.text.includes('history-limit'), 'and the settings with it')
check(stripped.text === existing.trim(), "the user's content is all that is left")

const nothing = strip(existing)
check(!nothing.removed, 'strip on a file with no block reports nothing removed')
check(nothing.text === existing.trim(), 'and changes nothing')

// A stray BEGIN with no END is taken to the end — the safe reading, since the
// alternative leaves our `set` lines behind while claiming to have cleared them.
const truncated = strip(`${existing}\n${BEGIN}\nset -g mouse on\n`)
check(!truncated.text.includes('mouse'), 'a block with no closing guard is removed to the end')

// Round trip: strip then apply rebuilds the same block when nothing changed.
check(apply(onto) === onto, 'strip-then-apply is stable')

// MARK: - installed

check(installed(onto), 'a file with the block reports as installed')
check(!installed(existing), 'a file without it does not')
check(!installed(''), 'an empty file is not installed')

if (failures > 0) {
  console.log(`\nTMUX_DEFAULTS_FAIL  (${failures} of ${checks} failed)`)
  process.exit(1)
}
console.log(`\nTMUX_DEFAULTS_PASS  (${checks} checks)`)