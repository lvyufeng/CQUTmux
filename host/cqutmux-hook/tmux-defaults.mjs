// The tmux defaults Moshi recommends, and the rules for writing them into
// ~/.tmux.conf.
//
// Moshi's `moshi-skill` ships a short list of tmux settings it asks you to put
// in your config: a large scrollback, mouse on, and 1-based pane/window
// indices. Without them the app's terminal feels wrong in ways that never name
// tmux — a scrollback that stops a few hundred lines up, a mouse that does not
// select, a pane numbered 0. CQUTMux's counterpart to that advice is this
// command.
//
// The rules live here, apart from the file writing, for the same reason the
// locale block does: both halves fail quietly. A block appended twice leaves
// four settings set twice with the last winning; a removal that leaves a stray
// `set` behind changes a user's tmux in a way they do not see until a pane
// opens in the wrong place. Pure string functions, so
// scripts/tmux-defaults-check.sh can drive them on a machine with no tmux.
//
// What this module must NOT do, and the reason it is written the way it is:
//
//   - It never rewrites or reorders a line the user wrote. A setting already
//     present is present even with a different value — `set -g history-limit
//     5000` is a choice, and fighting it would be this tool deciding it knows
//     the user's scrollback better than they do.
//   - It never touches the `update-environment` line. That line is a separate
//     feature (Settings → Integrations in the app documents it; it is typed by
//     hand, not written by any command here) and it is not one of the four
//     settings below, so it falls outside this module's parser entirely. The
//     block adds nothing to it and `strip` removes nothing of it.

/** The block's guards. The same shape as the locale block, so a reader who has
 *  seen one recognises the other — and deliberately not a plain tmux comment
 *  someone would hand-write, so the block is unmistakable in a diff. */
export const BEGIN = '# >>> cqutmux tmux-defaults >>>'
export const END = '# <<< cqutmux tmux-defaults <<<'

/** The settings we recommend, one canonical line each.
 *
 *  `option` is the tmux option *name* and is what "already present" is judged
 *  on; the line is only what we would write if it were missing. The whole point
 *  is that presence, not value, is the test — see the note at the top. */
export const DEFAULTS = [
  // A few hundred lines of scrollback is the tmux default, which is less than
  // one screen of a build log. 100000 is Moshi's number and the one its users
  // are used to finding.
  { option: 'history-limit', line: 'set -g history-limit 100000' },
  // Without this, a drag in the terminal selects tmux's own text and the app's
  // selection gestures do nothing.
  { option: 'mouse', line: 'set -g mouse on' },
  // 1-based indices match the app's tab row and every screenshot of Moshi's own
  // setup; 0-based windows cost a mental off-by-one on every `Ctrl-b 2`.
  { option: 'base-index', line: 'set -g base-index 1' },
  // `pane-base-index` is a *window* option, hence `setw`, while the three above
  // are server options. Writing it with `set` is accepted by tmux but has no
  // effect, which is exactly the silent miss this line exists to avoid.
  { option: 'pane-base-index', line: 'setw -g pane-base-index 1' },
]

/** The tmux commands that set an option. `set`/`set-option` and
 *  `setw`/`set-window-option` are the same command under two names and one
 *  spelling each; a config may use any of them. */
const SET_COMMANDS = new Set(['set', 'set-option', 'setw', 'set-window-option'])

/** Splits a line on `;`, which tmux treats as a command separator, without
 *  splitting one that sits inside quotes.
 *
 *  A naive split would read the `;` in `set -g status-left "foo; bar"` as a
 *  command boundary and then parse `bar"` as though it were a command — which
 *  is harmless until a quoted value happens to contain something that looks
 *  like one of our four settings, at which point a setting the user never made
 *  is reported as present and we silently skip writing it. */
function splitCommands(line) {
  const parts = []
  let current = ''
  let quote = null
  for (const ch of line) {
    if (quote) {
      if (ch === quote) quote = null
      current += ch
    } else if (ch === '"' || ch === "'") {
      quote = ch
      current += ch
    } else if (ch === ';') {
      parts.push(current)
      current = ''
    } else {
      current += ch
    }
  }
  parts.push(current)
  return parts
}

/** One `set` command, reduced to the option name and the value written. */
function parseSetCommand(tokens) {
  if (!SET_COMMANDS.has(tokens[0])) return null
  // Walk past the flags to the option name. `-t` is the one flag that takes a
  // *separate* argument (a target), so its value must be skipped or it would be
  // mistaken for the option name in `setw -t 0:1 pane-base-index 1`.
  let i = 1
  for (; i < tokens.length; i++) {
    const token = tokens[i]
    if (!token.startsWith('-')) break
    if (token === '-t' || token === '--target') i++
  }
  const option = tokens[i]
  if (!option) return null
  // The value is whatever follows; a bare `set -g mouse` (no value) is a query,
  // not an assignment, and carries none.
  return { option, value: tokens[i + 1] ?? null }
}

/**
 * Every option a config file sets, in file order.
 *
 * Comment lines are skipped; blank lines are skipped; a line that is not a
 * `set` command is ignored entirely, which is what keeps the `update-environment`
 * line — `set-option -ga update-environment " CQUTMUX_CLIENT"` — out of the
 * result: its option name is `update-environment`, one we never ask about.
 */
export function parseOptions(text) {
  const found = []
  const lines = String(text ?? '').split('\n')
  for (const raw of lines) {
    const line = raw.trim()
    if (!line || line.startsWith('#')) continue
    for (const command of splitCommands(line)) {
      const tokens = command.trim().split(/\s+/)
      if (!tokens[0]) continue
      const parsed = parseSetCommand(tokens)
      if (parsed) found.push({ ...parsed, line })
    }
  }
  return found
}

/**
 * The state of each recommended setting in `text`, for reporting.
 *
 * `present` is judged on the option name alone: a setting written with another
 * value is present, and the report says which line so the user can see the
 * difference rather than being told their choice is wrong.
 */
export function inspect(text) {
  const options = parseOptions(text)
  return DEFAULTS.map(d => {
    const found = options.find(o => o.option === d.option)
    return {
      option: d.option,
      recommended: d.line,
      present: Boolean(found),
      line: found ? found.line : null,
      matchesRecommended: Boolean(found) && found.line === d.line,
    }
  })
}

/** Whether `text` already carries our block. */
export function installed(text) {
  return String(text ?? '').includes(BEGIN)
}

/**
 * `text` with our block removed, and whether there was one to remove.
 *
 * A block whose END guard is missing — a hand-edited or half-removed file — is
 * taken to run to the end, the safe reading: the alternative leaves our `set`
 * lines behind while claiming to have cleared them. The `removed` flag lets a
 * caller that found nothing leave the file byte-for-byte untouched instead of
 * writing back a version with its trailing blank lines trimmed.
 */
export function strip(text) {
  const lines = String(text ?? '').split('\n')
  const kept = []
  let inside = false
  let removed = false
  for (const line of lines) {
    if (line.trim() === BEGIN) {
      inside = true
      removed = true
      continue
    }
    if (inside && line.trim() === END) {
      inside = false
      continue
    }
    if (!inside) kept.push(line)
  }
  // Drop the trailing blank lines the block's absence leaves, so writing it
  // again does not grow the file by a blank line on every run.
  while (kept.length && kept[kept.length - 1].trim() === '') kept.pop()
  return { text: kept.join('\n'), removed }
}

/** The delimited block carrying the given recommended lines, ending in a
 *  newline so it joins cleanly to whatever came before it. */
export function block(entries) {
  return [
    BEGIN,
    '# Written by `cqutmux tmux-defaults --write`. Removed by `cqutmux tmux-defaults --unset`.',
    ...entries.map(e => e.line),
    END,
    '',
  ].join('\n')
}

/**
 * `text` with a block containing exactly the settings it is missing, or
 * `text` unchanged when there is nothing to add.
 *
 * The existing block is stripped first and the missing set is computed from
 * what remains — the user's own lines. That is what makes a re-run idempotent
 * (the block's own lines are not mistaken for the user's, so the same block is
 * rebuilt rather than a second one appended) and what makes the user's choice
 * win (a setting they added since the last run is now present, so it drops out
 * of the block on its own).
 */
export function apply(text) {
  const original = String(text ?? '')
  const stripped = strip(original)
  const entries = inspect(stripped.text)
    .filter(report => !report.present)
    .map(report => DEFAULTS.find(d => d.option === report.option))

  if (entries.length === 0) {
    // Nothing missing. If a block was there it must have repeated lines the
    // user now sets themselves, so drop it; if there was none, hand back the
    // original untouched rather than a whitespace-normalised rewrite of it.
    return stripped.removed ? stripped.text : original
  }
  const body = stripped.text === '' ? '' : stripped.text + '\n\n'
  return body + block(entries)
}