// Generates the bundled theme catalogue in `App/Features/Settings/ThemeGallery.swift`
// from a directory of iTerm2-Color-Schemes `.itermcolors` files.
//
// Moshi's gallery is a set of named terminal themes re-fetchable by slug. That
// collection is public: `mbadolato/iTerm2-Color-Schemes` (MIT) publishes the same
// themes under the same names — 571 of Moshi's 573 published slugs appear in it,
// with full palettes. So the gallery here is that collection rather than a
// hand-written handful, and this script is how it is produced: hand-copying
// several hundred palettes is where a wrong hex digit hides.
//
// Usage:
//   node scripts/theme-gallery/generate.mjs <schemes-dir>
//
// It rewrites the `static let entries` block in ThemeGallery.swift in place,
// leaving the prose header and the helpers untouched. `plutil` does the plist
// parsing (macOS) rather than a hand-rolled XML reader that would get an edge
// case wrong.
//
// Two decisions worth recording:
//   - dark/light is *derived* from the background's luminance, because the
//     source files do not carry a mode. A background lighter than mid-grey is a
//     light theme; that is the same rule the gallery's own label needs.
//   - slug is computed with the exact algorithm `ThemeGallery.slug` uses, not
//     re-derived here, or a re-import would create a duplicate. The parity is
//     asserted by scripts/theme-gallery-check.sh, which parses every entry.

import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'

const dir = process.argv[2]
if (!dir) {
  console.error('usage: generate.mjs <schemes-dir>')
  process.exit(1)
}

// The same transformation as `ThemeGallery.slug` (Swift): lowercase, every
// non-alphanumeric to `-`, collapse runs, trim. Kept byte-identical to the
// Swift so a generated slug and an imported id can never disagree.
function slug(name) {
  const mapped = [...name.toLowerCase()].map(c => /[a-z0-9]/.test(c) ? c : '-')
  return mapped.join('').split('-').filter(Boolean).join('-')
}

// One sRGB component (0..1) to two hex digits. The values arrive as floats; a
// component at or above 1 is a saturated channel, and clamping stops a rounding
// error from producing a 5-digit "colour" that the parser then rejects.
function hex(c) {
  const n = Math.max(0, Math.min(255, Math.round(c * 255)))
  return n.toString(16).padStart(2, '0')
}

// The 16 ANSI slots, in the order the theme document names them.
const ANSI = [
  ['black', 0], ['red', 1], ['green', 2], ['yellow', 3],
  ['blue', 4], ['magenta', 5], ['cyan', 6], ['white', 7],
  ['brightBlack', 8], ['brightRed', 9], ['brightGreen', 10], ['brightYellow', 11],
  ['brightBlue', 12], ['brightMagenta', 13], ['brightCyan', 14], ['brightWhite', 15],
]

function readPlist(path) {
  const json = execFileSync('plutil', ['-convert', 'json', '-o', '-', path], { encoding: 'utf8' })
  return JSON.parse(json)
}

function colour(plist, key) {
  const c = plist[key]
  if (!c) return null
  return hex(c['Red Component']) + hex(c['Green Component']) + hex(c['Blue Component'])
}

function luminance(hexRgb) {
  const r = parseInt(hexRgb.slice(0, 2), 16) / 255
  const g = parseInt(hexRgb.slice(2, 4), 16) / 255
  const b = parseInt(hexRgb.slice(4, 6), 16) / 255
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

const files = readdirSync(dir).filter(f => f.endsWith('.itermcolors')).sort()
const entries = []
const skipped = []

for (const file of files) {
  const name = file.slice(0, -'.itermcolors'.length)
  let plist
  try {
    plist = readPlist(join(dir, file))
  } catch {
    skipped.push(`${name}: unreadable plist`)
    continue
  }
  const colors = {}
  let missing = false
  for (const [key, index] of ANSI) {
    const value = colour(plist, `Ansi ${index} Color`)
    if (!value) { missing = true; break }
    colors[key] = value
  }
  const bg = colour(plist, 'Background Color')
  const fg = colour(plist, 'Foreground Color')
  const cursor = colour(plist, 'Cursor Color') || fg
  if (missing || !bg || !fg) {
    skipped.push(`${name}: missing ${missing ? 'an ANSI slot' : 'background/foreground'}`)
    continue
  }
  entries.push({ name, slug: slug(name), dark: luminance(bg) < 0.5, bg, fg, cursor, colors })
}

// Sort by name, case-insensitively, so the gallery reads alphabetically the way
// the source list does rather than in filesystem order.
entries.sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()))

// Drop slug collisions, keeping the first. A slug is not a free label: it must
// equal the id `ThemeImport` derives from the theme's own name, or a re-import
// by slug adds a duplicate instead of updating. So two names that slugify the
// same way are a real conflict — the source has both `Dracula` and `Dracula+`,
// which both reduce to `dracula` — and the fix is to ship one, not to invent a
// second slug that the parser would never produce.
const seen = new Set()
const deduped = []
const dropped = []
for (const e of entries) {
  if (seen.has(e.slug)) { dropped.push(`${e.name} (slug ${e.slug})`); continue }
  seen.add(e.slug)
  deduped.push(e)
}
entries.length = 0
entries.push(...deduped)

const lines = entries.map(e => {
  const pairs = Object.entries(e.colors).map(([k, v]) => `"${k}": "${v}"`)
  const wrapped = []
  for (let i = 0; i < pairs.length; i += 4) wrapped.push('            ' + pairs.slice(i, i + 4).join(', ') + ',')
  return `        entry("${e.name}", dark: ${e.dark}, bg: "${e.bg}", fg: "${e.fg}", cursor: "${e.cursor}", colors: [\n${wrapped.join('\n')}\n        ]),`
}).join('\n')

const block = `    static let entries: [Entry] = [\n${lines}\n    ]`

const swiftPath = new URL('../../App/Features/Settings/ThemeGallery.swift', import.meta.url).pathname
const swift = readFileSync(swiftPath, 'utf8')
const marker = '    static let entries: [Entry] = ['
const start = swift.indexOf(marker)
if (start < 0) { console.error('entries marker not found'); process.exit(1) }
const end = swift.indexOf('\n    ]', start)
if (end < 0) { console.error('entries block end not found'); process.exit(1) }
writeFileSync(swiftPath, swift.slice(0, start) + block + swift.slice(end + '\n    ]'.length))

console.log(`wrote ${entries.length} entries`)
if (skipped.length) console.log(`skipped ${skipped.length}:\n  ` + skipped.join('\n  '))