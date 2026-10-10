// The diff-viewer page rules, checked with plain node.
//
// A diff is arbitrary repository text — a source file can contain `<script>`,
// and a filename can contain anything the filesystem allows. A page built by
// concatenation breaks or *runs* on the content it was meant to display, so the
// escaping and the line classification are asserted here rather than trusted.

import { escapeHtml, parseUnifiedDiff, pathFromHeader, renderDiffHtml }
  from '../../host/cqutmux-hook/diffpage.mjs'

let failures = 0
let checks = 0
function check(condition, label) {
  checks += 1
  if (condition) console.log(`PASS  ${label}`)
  else { failures += 1; console.log(`FAIL  ${label}`) }
}

console.log('— escaping —')
check(escapeHtml('<script>') === '&lt;script&gt;', 'a tag is neutralised')
check(escapeHtml('a & b') === 'a &amp; b', 'an ampersand is escaped')
check(escapeHtml('"x"') === '&quot;x&quot;', 'a double quote is escaped')
check(escapeHtml("it's") === 'it&#39;s', 'a single quote is escaped')
// Order matters: escaping & last would turn the & in &lt; into &amp;lt;.
check(escapeHtml('<a>') === '&lt;a&gt;', 'the ampersand is escaped first, not last')

console.log('\n— reading a unified diff —')
const DIFF = [
  'diff --git a/a.js b/a.js',
  'index 111..222 100644',
  '--- a/a.js',
  '+++ b/a.js',
  '@@ -1,3 +1,3 @@',
  ' line1',
  '-old',
  '+new',
  ' line3',
  'diff --git a/b.js b/b.js',
  '@@ -0,0 +1 @@',
  '+added',
].join('\n')
const files = parseUnifiedDiff(DIFF)
check(files.length === 2, `two file blocks are read (got ${files.length})`)
check(files[0].lines.filter(l => l.type === 'add').length === 1, 'one addition in the first file')
check(files[0].lines.filter(l => l.type === 'del').length === 1, 'one deletion')
check(files[0].lines.filter(l => l.type === 'context').length === 2, 'two context lines')
check(files[0].lines.filter(l => l.type === 'hunk').length === 1, 'one hunk header')
check(files[0].lines.filter(l => l.type === 'meta').length === 3, `three metadata lines, the index and the ---/+++ pair (got ${files[0].lines.filter(l => l.type === 'meta').length})`)
check(files[1].lines.filter(l => l.type === 'add').length === 1, 'the second file keeps its own lines')

// The mark is not part of the text: a `+foo` line's content is `foo`, or the
// gutter would show a `+` that is really in the file.
check(files[0].lines.find(l => l.type === 'add').text === 'new', 'the + is stripped from an addition')
check(files[0].lines.find(l => l.type === 'del').text === 'old', 'the - from a deletion')
check(files[0].lines.find(l => l.type === 'context').text === 'line1', 'the space from context')

// A context line whose content starts with `+` must stay context: inside a hunk
// the first character is the mark, so a line beginning with a space is context
// whatever follows.
const tricky = parseUnifiedDiff([
  'diff --git a/x b/x', '@@ -1 +1 @@', ' +not-an-addition',
].join('\n'))
// lines[0] is the hunk header; the context line follows it.
check(tricky[0].lines[1].type === 'context', 'a context line beginning with + after the mark stays context')
check(tricky[0].lines[1].text === '+not-an-addition', 'and keeps its leading + as content')

// No-hunk file (a mode change or a binary file): metadata only, and it must not
// crash or invent a body.
const noHunk = parseUnifiedDiff(['diff --git a/bin b/bin', 'Binary files differ'].join('\n'))
check(noHunk.length === 1, 'a file with no hunk is still one block')
check(noHunk[0].lines.every(l => l.type === 'meta'), 'whose lines are all metadata')

check(parseUnifiedDiff('').length === 0, 'an empty diff is no blocks')

console.log('\n— the path from the header —')
const renamed = pathFromHeader('diff --git a/old/name.js b/new/name.js')
check(renamed.from === 'old/name.js', 'the source path is read')
check(renamed.path === 'new/name.js', 'and the destination, which differs on a rename')
check(pathFromHeader('not a header').path === '', 'a non-header yields no path')

console.log('\n— the page —')
const html = renderDiffHtml({
  files: [{ status: 'M', path: 'a.js' }],
  diff: DIFF,
  title: '/home/me/repo',
  version: '1.0.0',
})
check(html.startsWith('<!doctype html>'), 'a doctype is emitted')
check(html.includes('<h1>/home/me/repo</h1>'), 'the repo path is the heading')
check(html.includes('1 changed file(s)'), 'the count is stated')
check(html.includes('cqutmux 1.0.0'), 'the version is shown')

// The one that matters: repository content cannot become markup.
const hostile = renderDiffHtml({
  files: [{ status: 'M', path: '<img src=x onerror=alert(1)>.js' }],
  diff: 'diff --git a/x b/x\n@@ -1 +1 @@\n+<script>alert(1)</script>',
  title: '</title><script>alert(2)</script>',
})
check(!hostile.includes('<script>alert(1)</script>'), 'a script in a diff line is escaped')
check(!hostile.includes('<script>alert(2)'), 'a script in the title is escaped')
check(!hostile.includes('<img src=x'), 'a tag in a filename is escaped')
check(hostile.includes('&lt;script&gt;'), 'and the escaped form is what is present')

// A filename also lands in an element id, where a quote would end the attribute.
check(!/id="[^"]*<img/.test(hostile), 'a filename cannot break out of the id attribute')

console.log('\n— the empty states —')
const clean = renderDiffHtml({ files: [], diff: '', title: '/repo' })
check(clean.includes('No uncommitted changes'), 'a clean tree says so')
check(!clean.includes('<ul></ul>'), 'and draws no empty list')

// A changed-but-binary repo: files listed, no textual diff. Saying "no changes"
// here would be false, so the two states are worded differently.
const binary = renderDiffHtml({ files: [{ status: 'M', path: 'logo.png' }], diff: 'diff --git a/logo.png b/logo.png\nBinary files differ' })
check(binary.includes('1 changed file(s)'), 'a binary change still counts as a change')
check(!binary.includes('No uncommitted changes'), 'and is not called no changes')

if (failures > 0) {
  console.log(`\nDIFFPAGE_FAIL  (${failures} of ${checks} failed)`)
  process.exit(1)
}
console.log(`\nDIFFPAGE_PASS  (${checks} checks)`)
