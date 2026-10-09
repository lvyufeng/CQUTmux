// Checks the command-history reader, which parses a file the shell owns.
//
// A separate .mjs rather than an inline `node -e` heredoc: the escaping rules
// under test are themselves about backslashes and quotes, and burying the
// fixtures inside a bash double-quoted string means the test's own quoting has
// to be read through two layers of escaping to find out what it is actually
// asserting.
//
// The failures here are quiet in a specific way: a mis-parsed history does not
// error, it offers the user a command that is subtly not the one they ran.
// That is worse than an empty list, because the command gets typed into a shell
// and run.
//
// Three things are worth pinning:
//
// 1. Both formats. A shell can be upgraded under an existing history file, so
//    plain and extended records really do appear in the same file, and the
//    extended prefix must be stripped rather than shown as part of the command.
// 2. The separator in the extended header is the *first* one. `: 1:0;echo a; b`
//    is one command called `echo a; b`, not a command called `a`.
// 3. A line ending in a backslash is a continuation, and joining with a space
//    instead of a newline silently changes what a loop or a quoted string
//    means.

import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { parseHistory, commandHistory } from '../../host/cqutmux-hook/history.mjs'

const OUT = process.argv[2]
if (!OUT) { console.error('usage: main.mjs <tmpdir>'); process.exit(2) }

let failures = 0
let checks = 0
function check(condition, label) {
  checks++
  if (condition) { console.log('PASS  ' + label) }
  else { failures++; console.log('FAIL  ' + label) }
}

// MARK: - Extended format

const extended = parseHistory(': 1700000000:0;git status\n: 1700000060:2;cargo test\n')
check(extended.length === 2, 'two extended records parse to two commands')
check(extended[0].command === 'cargo test', 'newest first, so the file order is reversed')
check(extended[1].command === 'git status', 'and the older one follows it')
check(extended[1].at === 1700000000000,
  'the epoch seconds become milliseconds, which is what the app formats')
check(!extended[1].command.includes(':'),
  'the header is stripped, not shown as part of the command')

// The header's separator is the first one. Splitting on the last would put the
// command's own semicolons into the timestamp and lose the command's front.
const semis = parseHistory(': 1700000000:0;echo a; echo b\n')
check(semis.length === 1 && semis[0].command === 'echo a; echo b',
  'a semicolon in the command survives — the split is on the first one')
check(semis[0].at === 1700000000000, 'and the timestamp is still read')

// MARK: - Plain format

const plain = parseHistory('ls -la\ncd /srv\n')
check(plain.length === 2 && plain[0].command === 'cd /srv',
  'plain records parse, newest first')
check(plain[0].at === null, 'a plain record has no timestamp, which is not an error')

// A command that begins with a colon is a command, not a header.
const colonish = parseHistory(':(){ :|:& };:\n')
check(colonish[0].command === ':(){ :|:& };:',
  'a command that starts with a colon is not mistaken for a header')

// MARK: - The two formats interleaved

const mixed = parseHistory('ls\n: 1700000000:0;git log\ncd /tmp\n')
check(mixed.length === 3, 'a file with both formats yields every record')
check(mixed.map(r => r.command).join('|') === 'cd /tmp|git log|ls',
  'in file order, reversed')

// MARK: - Continuations

// The backslash is removed and the join is a newline, because the shell saw a
// newline. Joining with a space would turn a loop into nonsense.
const joined = parseHistory('for f in a b\\\ndo echo $f\\\ndone\n')
check(joined.length === 1, 'a continued command is one record, not three')
check(joined[0].command === 'for f in a b\ndo echo $f\ndone',
  'and the lines are joined with newlines, which is what the shell saw')
check(!joined[0].command.includes('\\'), 'with the continuation markers removed')

// An extended record can be continued too. The continuation is the only place
// the two formats interact, and getting it wrong loses either the timestamp or
// the command's second line.
const extendedJoined = parseHistory(': 1700000000:0;git commit -m \\\n"a message"\n')
check(extendedJoined.length === 1, 'a continued extended record is one record')
check(extendedJoined[0].command === 'git commit -m \n"a message"',
  'with both lines kept and the join a newline, as the shell saw it')
check(extendedJoined[0].at === 1700000000000,
  'and still carrying its timestamp, which is on the first line only')

// MARK: - Degenerate input

check(parseHistory('').length === 0, 'an empty file has no commands')
check(parseHistory('\n\n\n').length === 0, 'and neither does one of blank lines')
check(parseHistory(': not-a-number:x;ls\n')[0].command === 'ls',
  'a malformed timestamp still yields the command, without a time')
check(parseHistory(': garbage\n').every(r => r.command), 'a headerless colon line is not empty')

// MARK: - The walk over a fake home

const home = join(OUT, 'home')
mkdirSync(home, { recursive: true })
writeFileSync(join(home, '.zsh_history'),
  ': 1700000010:0;cargo test\n: 1700000020:0;git push\nls\n')
writeFileSync(join(home, '.bash_history'), 'make -j8\n')

const found = await commandHistory({ home, shell: 'zsh' })
const commands = found.commands.map(c => c.command)
check(commands.includes('cargo test'), 'a zsh command is discovered')
check(commands.includes('git push'), 'and another')
// A plain record carries no timestamp, so it keeps the position the file gave
// it. Treating the absence as "epoch 0" would sink it below every dated record
// and drop the command the user just ran to the bottom of the list.
check(commands.includes('ls'), 'a plain record is still offered')
check(commands.indexOf('ls') < commands.indexOf('git push'),
  'and stays where the file put it, since its position is the only time it has')
check(!commands.includes('make -j8'),
  'bash history is left alone when the shell is known to be zsh')
check(found.commands.every(c => c.shell === 'zsh'), 'each entry names the shell it came from')

const both = await commandHistory({ home, shell: '' })
check(both.commands.some(c => c.command === 'make -j8'),
  'with no shell known, both files are read')

// A command run many times should appear once. Running `ls` forty times in a
// session must not be forty rows in a picker.
writeFileSync(join(home, '.zsh_history'),
  ': 1700000010:0;ls\n: 1700000020:0;ls\n: 1700000030:0;ls\n')
const deduped = await commandHistory({ home, shell: 'zsh' })
check(deduped.commands.length === 1, 'a repeated command appears once')
check(deduped.commands[0].at === 1700000030000,
  'keeping the most recent time, which is when it was last useful')

const empty = await commandHistory({ home: join(OUT, 'nothing'), shell: 'zsh' })
check(empty.commands.length === 0, 'a home with no history yields an empty list')

writeFileSync(join(home, '.zsh_history'),
  Array.from({ length: 20 }, (_, i) =>
    ': 1700000' + String(i).padStart(3, '0') + ':0;cmd' + i).join('\n') + '\n')
const limited = await commandHistory({ home, shell: 'zsh', limit: 5 })
check(limited.commands.length === 5, 'the limit is honoured')

console.log('')
if (failures === 0) {
  console.log(`SHELL_HISTORY_PASS  (${checks} checks)`)
} else {
  console.log(`SHELL_HISTORY_FAIL  (${failures} of ${checks} failed)`)
  process.exit(1)
}