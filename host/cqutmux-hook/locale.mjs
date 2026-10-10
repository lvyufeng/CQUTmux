// Writing LANG and LC_ALL into a shell's startup files.
//
// Typing `export LANG=…` into the session fixes the interactive shell, and only
// that one: an agent that spawns a shell of its own — a hook, a `bash -c`, a
// subprocess — gets a non-interactive shell that never reads the preamble we
// typed, and inherits whatever locale the host came up with. The two files that
// cover those are ~/.zshenv (zsh reads it for *every* invocation, interactive or
// not) and ~/.bashrc.
//
// The rules live here, apart from the file writing, because both halves of this
// fail quietly: a block that is appended twice sets the variable twice with the
// last one winning, and a removal that leaves a stray line behind changes a
// shell's startup in a way nobody sees until it breaks something. Pure string
// functions, so scripts/locale-check.sh can drive them.

/** The block's guards. Deliberately not a shell comment convention people also
 *  hand-write, so the block is unmistakable in a diff and can be found even if
 *  the user has edited around it. */
export const BEGIN = '# >>> cqutmux locale >>>'
export const END = '# <<< cqutmux locale <<<'

/** A locale name is pasted into a shell line unquoted, so it is restricted to
 *  the characters a locale name is made of. A value carrying a newline or a `;`
 *  would not set a variable — it would run a command, in every shell on the
 *  host, for every future login. This is the same gate the app applies before
 *  it sends one; it is repeated here because this program is a separate entry
 *  point that a user can call directly. */
export function isSafeLocale(name) {
  if (typeof name !== 'string' || !name) return false
  // Letters, digits, `_`, `.`, `-`, `@` — the whole of what a locale name uses
  // (en_US.UTF-8, de_DE.UTF-8@euro, C.UTF-8).
  if (!/^[A-Za-z0-9_.@-]+$/.test(name)) return false
  // And it has to be a UTF-8 one, since that is the reason for setting it:
  // exporting C or POSIX would turn correct UTF-8 output into mojibake, which is
  // the failure this feature exists to prevent.
  const encoding = name.split('@')[0].split('.').slice(1).join('.').toLowerCase()
  return encoding === 'utf-8' || encoding === 'utf8'
}

/** The block that sets the locale, ending with a newline. */
export function block(locale) {
  if (!isSafeLocale(locale)) throw new Error(`refusing to write an unsafe locale: ${locale}`)
  return [
    BEGIN,
    '# Written by `cqutmux locale`. Removed by `cqutmux locale unset`.',
    `export LANG=${locale}`,
    // Both, and LC_ALL last: a host whose /etc/profile exports its own LC_ALL
    // would otherwise ignore the LANG we set, and that host is exactly the one
    // where a mis-set locale causes trouble.
    `export LC_ALL=${locale}`,
    END,
    '',
  ].join('\n')
}

/** `text` with any existing cqutmux block removed. */
export function strip(text) {
  const lines = String(text ?? '').split('\n')
  const kept = []
  let inside = false
  for (const line of lines) {
    if (line.trim() === BEGIN) {
      inside = true
      continue
    }
    if (inside && line.trim() === END) {
      inside = false
      continue
    }
    if (!inside) kept.push(line)
  }
  // Trim trailing blank lines the removed block may have left, so re-applying
  // does not grow the file by a blank line each time.
  while (kept.length && kept[kept.length - 1].trim() === '') kept.pop()
  return kept.join('\n')
}

/** `text` with the locale block present exactly once, at the end. */
export function apply(text, locale) {
  const base = strip(text)
  const body = base === '' ? '' : base + '\n\n'
  return body + block(locale)
}

/** Whether `text` already carries our block. */
export function installed(text) {
  return String(text ?? '').includes(BEGIN)
}

/**
 * Whether a shell reads `file`, and so whether writing the block there is worth
 * anything.
 *
 * zsh reads ~/.zshenv for every invocation, which is what makes it the one file
 * that actually reaches a hook-spawned shell. bash reads ~/.bashrc only when it
 * is interactive, so for bash the block is a best effort — recorded here rather
 * than papered over, because a claim that it covers non-interactive bash would
 * be false.
 */
export const FILES = [
  { name: '.zshenv', shell: 'zsh', nonInteractive: true },
  { name: '.bashrc', shell: 'bash', nonInteractive: false },
]