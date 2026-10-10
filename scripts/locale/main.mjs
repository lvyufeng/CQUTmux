// The rc-injection rules, checked without a host.
//
// Both halves fail silently. A block appended twice sets the variable twice and
// the last one wins; a removal that leaves a stray line behind changes a shell's
// startup in a way nobody sees until something breaks. So the string functions
// are driven directly, and the command itself is run in a throwaway HOME.

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
  BEGIN, END, isSafeLocale, block, strip, apply, installed, FILES,
} = await import('../../host/cqutmux-hook/locale.mjs')

// MARK: - What may be written at all

// The value is pasted into a shell line unquoted, in every future shell on the
// host. Anything that is not a locale name would not set a variable — it would
// run a command.
check(isSafeLocale('en_US.UTF-8'), 'en_US.UTF-8 is safe')
check(isSafeLocale('C.UTF-8'), 'C.UTF-8 is safe')
check(isSafeLocale('de_DE.UTF-8@euro'), 'a modifier locale is safe')
check(isSafeLocale('en_US.utf8'), 'the utf8 spelling is safe')
check(!isSafeLocale(''), 'an empty locale is refused')
check(!isSafeLocale('C'), 'C is refused — it is not UTF-8, and setting it mojibakes output')
check(!isSafeLocale('POSIX'), 'POSIX is refused')
check(!isSafeLocale('en_US.ISO-8859-1'), 'a non-UTF-8 encoding is refused')
check(!isSafeLocale('en_US.UTF-8\nrm -rf /'), 'a locale with a newline is refused')
check(!isSafeLocale('en_US.UTF-8; rm -rf /'), 'a locale with a semicolon is refused')
check(!isSafeLocale('$(whoami)'), 'a locale with a command substitution is refused')
check(!isSafeLocale('`id`'), 'a locale with backticks is refused')

// A hostile value that *also* ends in a valid encoding. Without the
// character-set gate this passes the UTF-8 check and reaches a shell — the
// other refusals only hold because they happen to fail the encoding test too,
// so these are the cases that actually pin the character set.
check(!isSafeLocale('x;y.UTF-8'), 'a locale with a semicolon before a UTF-8 suffix is refused')
check(!isSafeLocale('$(id).UTF-8'), 'a command substitution before a UTF-8 suffix is refused')
check(!isSafeLocale('a b.UTF-8'), 'a locale with a space before a UTF-8 suffix is refused')
check(!isSafeLocale('a\nb.UTF-8'), 'a newline before a UTF-8 suffix is refused')

// `block` refuses rather than writing, so an unsafe value cannot reach a shell
// even if a caller forgets to test first.
let threw = false
try {
  block('en_US.UTF-8; rm -rf /')
} catch {
  threw = true
}
check(threw, 'block refuses an unsafe locale instead of writing it')

// MARK: - The block

const blockText = block('en_US.UTF-8')
check(blockText.includes('export LANG=en_US.UTF-8'), 'the block sets LANG')
check(blockText.includes('export LC_ALL=en_US.UTF-8'), 'and LC_ALL')
check(blockText.includes(BEGIN) && blockText.includes(END), 'the block is guarded on both sides')
check(blockText.endsWith('\n'), 'the block ends with a newline, so it joins to a file cleanly')

// LC_ALL comes after LANG: a host whose profile exports its own LC_ALL would
// otherwise ignore the LANG, and that host is where it matters.
check(blockText.indexOf('export LANG') < blockText.indexOf('export LC_ALL'),
      'LC_ALL is set after LANG')

// MARK: - Applying

// Onto a file that already has content: the user's lines stay, ours go last.
const existing = 'export PATH=/usr/bin\n'
const applied = apply(existing, 'en_US.UTF-8')
check(applied.startsWith('export PATH=/usr/bin\n'), "the user's own lines are kept")
check(applied.includes('export LANG=en_US.UTF-8'), 'and ours are added')
check(applied.indexOf('export PATH') < applied.indexOf('export LANG'), 'ours come after theirs')

// Applying twice must not stack a second block: the failure mode is a startup
// file that sets the variable twice with the last one winning.
const twice = apply(applied, 'en_US.UTF-8')
check(twice === applied, 'applying the same locale twice changes nothing')
check(twice.split(BEGIN).length - 1 === 1, 'the block appears exactly once after two applications')

// Changing the locale replaces the block rather than adding another.
const changed = apply(applied, 'de_DE.UTF-8')
check(changed.split(BEGIN).length - 1 === 1, 'changing the locale leaves one block')
check(changed.includes('de_DE.UTF-8') && !changed.includes('en_US.UTF-8'),
      'the new locale replaced the old one')

// Onto an empty file, and onto a file that does not exist yet (also empty
// string): neither should leave leading blank lines.
check(apply('', 'en_US.UTF-8').startsWith(BEGIN), 'an empty file starts with the block')
check(!apply('', 'en_US.UTF-8').startsWith('\n'), 'an empty file gets no leading blank line')
check(apply('', 'en_US.UTF-8').split(BEGIN).length - 1 === 1, 'and exactly one block')

// MARK: - Stripping

// Removal takes the whole block and no more of the user's file.
const stripped = strip(applied)
check(!stripped.includes(BEGIN), 'stripping removes the block')
check(stripped.includes('export PATH=/usr/bin'), "and leaves the user's lines")
check(stripped.trim() === 'export PATH=/usr/bin', 'with no trailing blank left behind')

// A file with nothing of ours is returned unchanged.
check(strip(existing) === existing.trim(), 'stripping a file with no block leaves its content')
check(strip('') === '', 'stripping an empty file gives an empty string')

// A hand-edited file with a stray BEGIN and no END: everything to the end is
// treated as part of the block, which is the safe reading — a half-removed block
// would otherwise leave our exports behind while claiming to have cleared them.
const truncated = `${existing}\n${BEGIN}\nexport LANG=en_US.UTF-8\n`
check(!strip(truncated).includes('export LANG'), 'a block with no closing guard is removed to the end')

// MARK: - installed

check(installed(applied), 'a file with the block reports as installed')
check(!installed(existing), 'a file without it does not')
check(!installed(''), 'an empty file is not installed')

// MARK: - The file list

// Both shells, and the honest record of which one is covered non-interactively.
check(FILES.some(f => f.name === '.zshenv'), '~/.zshenv is written')
check(FILES.some(f => f.name === '.bashrc'), '~/.bashrc is written')
check(FILES.find(f => f.name === '.zshenv').nonInteractive === true,
      '~/.zshenv is recorded as reaching non-interactive shells')
check(FILES.find(f => f.name === '.bashrc').nonInteractive === false,
      '~/.bashrc is recorded as interactive-only, rather than claimed as more')

if (failures > 0) {
  console.log(`\nLOCALE_FAIL  (${failures} of ${checks} failed)`)
  process.exit(1)
}
console.log(`\nLOCALE_PASS  (${checks} checks)`)