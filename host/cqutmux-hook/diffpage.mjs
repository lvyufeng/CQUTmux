// The HTML page `cqutmux diff` serves on loopback.
//
// Split into pure functions from the server that hosts them so the parts that
// fail silently can be checked with plain node. The one that matters most is
// escaping: a diff is arbitrary text from the repository — a source file can
// contain `<script>`, and a *filename* can contain anything the filesystem
// allows — so a page built by string concatenation is a page that breaks, or
// runs, on the content it was meant to display.

/// Escapes text for insertion into HTML element content or a quoted attribute.
export function escapeHtml(text) {
  return String(text)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;')
}

/// Splits a unified diff into per-file line lists.
///
/// One entry per `diff --git` block, each line tagged so the renderer can colour
/// it without re-parsing: `add`, `del`, `hunk`, `meta`, or `context`. A line is
/// classified by its first character, which is the format's own rule — but only
/// for lines that are not headers, because a context line whose content begins
/// with `+` would otherwise be read as an addition.
export function parseUnifiedDiff(diffText) {
  const files = []
  let current = null
  let inHunk = false

  for (const line of String(diffText).split('\n')) {
    if (line.startsWith('diff --git ')) {
      current = { header: line, lines: [] }
      files.push(current)
      inHunk = false
      continue
    }
    if (current === null) continue
    if (line.startsWith('@@')) {
      inHunk = true
      current.lines.push({ type: 'hunk', text: line })
      continue
    }
    if (!inHunk) {
      // Everything between `diff --git` and the first hunk is metadata:
      // `index …`, `--- a/…`, `+++ b/…`, mode lines.
      current.lines.push({ type: 'meta', text: line })
      continue
    }
    if (line.startsWith('+')) current.lines.push({ type: 'add', text: line.slice(1) })
    else if (line.startsWith('-')) current.lines.push({ type: 'del', text: line.slice(1) })
    else if (line.startsWith(' ')) current.lines.push({ type: 'context', text: line.slice(1) })
    else if (line.startsWith('\\')) current.lines.push({ type: 'meta', text: line })
    else current.lines.push({ type: 'context', text: line })
  }
  return files
}

/// The path a file block concerns, from its `diff --git a/x b/y` header.
///
/// Read from the header rather than invented: git writes both sides, and for a
/// rename they differ — showing only one would hide the move.
export function pathFromHeader(header) {
  const match = String(header).match(/^diff --git a\/(.*) b\/(.*)$/)
  if (!match) return { path: '', from: '' }
  return { path: match[2], from: match[1] }
}

/// Renders the whole page: a file list, and the diff beneath it.
///
/// `files` is the git status list (`{status, path}`), `diff` the unified text,
/// `title` the repo path. Everything the user typed or the repo contains goes
/// through `escapeHtml`; nothing is interpolated raw.
export function renderDiffHtml({ files = [], diff = '', title = '', version = '' } = {}) {
  const rows = files.map(file => {
    const status = escapeHtml(file.status || '?')
    const path = escapeHtml(file.path || '')
    return `<li><span class="s" data-s="${status}">${status}</span><a href="#${path}">${path}</a></li>`
  }).join('\n')

  const blocks = parseUnifiedDiff(diff).map(block => {
    const { path, from } = pathFromHeader(block.header)
    const heading = from && from !== path
      ? `${from} → ${path}`
      : path
    const body = block.lines.map(line => {
      const cls = line.type
      // The line's own leading `+`/`-`/space is not part of its text, so the
      // gutter is drawn from the class instead of relying on the character.
      return `<span class="l ${cls}">${escapeHtml(line.text) || '&nbsp;'}</span>`
    }).join('')
    return `<section id="${escapeHtml(path)}"><h2>${escapeHtml(heading)}</h2><pre>${body}</pre></section>`
  }).join('\n')

  const empty = files.length === 0
    ? '<p class="empty">No uncommitted changes.</p>'
    : ''

  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>cqutmux diff — ${escapeHtml(title)}</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 14px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; margin: 0; padding: 16px; }
  h1 { font-size: 15px; margin: 0 0 4px; }
  .meta { color: #777; font-size: 12px; margin-bottom: 16px; }
  ul { list-style: none; padding: 0; margin: 0 0 20px; }
  li { display: flex; gap: 8px; padding: 2px 0; }
  .s { min-width: 2ch; }
  .s[data-s="M"] { color: #b58900; }
  .s[data-s="A"] { color: #2aa198; }
  .s[data-s="D"] { color: #dc322f; }
  h2 { font-size: 13px; margin: 20px 0 6px; }
  pre { margin: 0; overflow-x: auto; }
  .l { display: block; white-space: pre; padding: 0 4px; }
  .add { background: rgba(42,161,152,.15); }
  .del { background: rgba(220,50,47,.15); }
  .hunk { color: #6c71c4; }
  .meta { color: #888; }
  .empty { color: #777; }
</style>
</head><body>
<h1>${escapeHtml(title)}</h1>
<p class="meta">${files.length} changed file(s)${version ? ` · cqutmux ${escapeHtml(version)}` : ''}</p>
${empty}
${rows ? `<ul>${rows}</ul>` : ''}
${blocks || '<p class="empty">No textual diff.</p>'}
</body></html>`
}
