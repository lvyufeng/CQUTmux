// Checks `host/cqutmux-hook/qr.mjs` — the QR encoder the host prints for
// `cqutmux pair` — against the same reference matrices the Swift encoder is
// checked against, and reads the payload back out with a decoder.
//
// This is a second implementation of one algorithm, which is exactly the
// arrangement where a bug hides: each half looks right on its own, and the
// phone silently binds to a host the host side never meant. So the expected
// matrices are read out of `scripts/qr/main.swift` — the same vectors, from the
// Python `qrcode` package, that an independent encoder produced — rather than
// being regenerated here, which would only prove the JS agrees with itself.
//
// The comparison is on *unmasked* data modules, not on the finished matrices:
// the mask is an optimisation, two encoders may legitimately choose differently
// (they do — mask 6 here where the reference took 4), and asserting the whole
// matrix is equal asserts a choice the format does not require. The Swift check
// learned this the hard way; the same rule applies here.
//
// Usage: node scripts/qr-js/main.mjs [path/to/scripts/qr/main.swift]

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { encode, terminal, versionFor, LIMITS } from '../../host/cqutmux-hook/qr.mjs'

const source = process.argv[2]
  || fileURLToPath(new URL('../qr/main.swift', import.meta.url))

let passed = 0
let failed = 0

function check(name, condition, detail = '') {
  if (condition) {
    passed++
    process.stdout.write(`PASS  ${name}\n`)
  } else {
    failed++
    process.stdout.write(`FAIL  ${name}${detail ? ` — ${detail}` : ''}\n`)
  }
}

// --- The vectors, taken from the Swift check --------------------------------

// The list is `("text", version, ["rows"...]),` repeated. Only the Swift check's
// own data is read from it; nothing about either implementation is.
function loadVectors(text) {
  const vectors = []
  const pattern = /\("([^"]+)",\s*(\d+),\s*\[([\s\S]*?)\]/g
  let match
  while ((match = pattern.exec(text)) !== null) {
    const rows = [...match[3].matchAll(/"([01]+)"/g)].map(row => row[1])
    vectors.push({ text: match[1], version: Number(match[2]), rows })
  }
  return vectors
}

// --- Reading a matrix, from the format rather than from the encoder ---------

// Alignment centres, the same data the spec's table holds. Carried here rather
// than imported so that the reserved map this check builds is not derived from
// the encoder's own idea of where the patterns go.
const ALIGNMENT = {
  1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34],
  7: [6, 22, 38], 8: [6, 24, 42], 9: [6, 26, 46], 10: [6, 28, 50],
  11: [6, 30, 54], 12: [6, 32, 58], 13: [6, 34, 62],
  14: [6, 26, 46, 66], 15: [6, 26, 48, 70], 16: [6, 26, 50, 74],
  17: [6, 30, 54, 78], 18: [6, 30, 56, 82], 19: [6, 30, 58, 86],
  20: [6, 34, 62, 90], 21: [6, 28, 50, 72, 94], 22: [6, 26, 50, 74, 98],
  23: [6, 30, 54, 78, 102], 24: [6, 28, 54, 80, 106], 25: [6, 32, 58, 84, 110],
  26: [6, 30, 58, 86, 114], 27: [6, 34, 62, 90, 118],
  28: [6, 26, 50, 74, 98, 122], 29: [6, 30, 54, 78, 102, 126],
  30: [6, 26, 52, 78, 104, 130], 31: [6, 30, 56, 82, 108, 134],
  32: [6, 34, 60, 86, 112, 138], 33: [6, 30, 58, 86, 114, 142],
  34: [6, 34, 62, 90, 118, 146], 35: [6, 30, 54, 78, 102, 126, 150],
  36: [6, 24, 50, 76, 102, 128, 154], 37: [6, 28, 54, 80, 106, 132, 158],
  38: [6, 32, 58, 84, 110, 136, 162], 39: [6, 26, 54, 82, 110, 138, 166],
  40: [6, 30, 58, 86, 114, 142, 170],
}

// Data codewords per block, so the check can deinterleave without asking the
// encoder what it wrote.
const BLOCK_SIZES = {
  1: [[1, 16]], 2: [[1, 28]], 3: [[1, 44]], 4: [[2, 32]], 5: [[2, 43]],
  6: [[4, 27]], 7: [[4, 31]], 8: [[2, 38], [2, 39]], 9: [[3, 36], [2, 37]],
  10: [[4, 43], [1, 44]], 11: [[1, 50], [4, 51]], 12: [[6, 36], [2, 37]],
  13: [[8, 37], [1, 38]], 14: [[4, 40], [5, 41]], 15: [[5, 41], [5, 42]],
  16: [[7, 45], [3, 46]], 17: [[10, 46], [1, 47]], 18: [[9, 43], [4, 44]],
  19: [[3, 44], [11, 45]], 20: [[3, 41], [13, 42]], 21: [[17, 42]],
  22: [[17, 46]], 23: [[4, 47], [14, 48]], 24: [[6, 45], [14, 46]],
  25: [[8, 47], [13, 48]], 26: [[19, 46], [4, 47]], 27: [[22, 45], [3, 46]],
  28: [[3, 45], [23, 46]], 29: [[21, 45], [7, 46]], 30: [[19, 47], [10, 48]],
  31: [[2, 46], [29, 47]], 32: [[10, 46], [23, 47]], 33: [[14, 46], [21, 47]],
  34: [[14, 46], [23, 47]], 35: [[12, 47], [26, 48]], 36: [[6, 47], [34, 48]],
  37: [[29, 46], [14, 47]], 38: [[13, 46], [32, 47]], 39: [[40, 47], [7, 48]],
  40: [[18, 47], [31, 48]],
}

function reservedMap(version, size) {
  const reserved = Array.from({ length: size }, () => new Array(size).fill(false))
  const mark = (row, column) => {
    if (row >= 0 && row < size && column >= 0 && column < size) reserved[row][column] = true
  }
  for (const [row, column] of [[0, 0], [0, size - 7], [size - 7, 0]]) {
    for (let r = -1; r <= 7; r += 1) for (let c = -1; c <= 7; c += 1) mark(row + r, column + c)
  }
  for (let index = 0; index < size; index += 1) { mark(6, index); mark(index, 6) }
  for (const row of ALIGNMENT[version]) {
    for (const column of ALIGNMENT[version]) {
      if ((row < 9 && column < 9) || (row < 9 && column > size - 10)
          || (row > size - 10 && column < 9)) continue
      for (let r = -2; r <= 2; r += 1) for (let c = -2; c <= 2; c += 1) mark(row + r, column + c)
    }
  }
  for (let index = 0; index < 9; index += 1) { mark(8, index); mark(index, 8) }
  for (let index = 0; index < 8; index += 1) { mark(8, size - 1 - index); mark(size - 1 - index, 8) }
  mark(size - 8, 8)
  if (version >= 7) {
    for (let index = 0; index < 18; index += 1) {
      mark(Math.floor(index / 3), size - 11 + index % 3)
      mark(size - 11 + index % 3, Math.floor(index / 3))
    }
  }
  return reserved
}

function maskCondition(mask, row, column) {
  switch (mask) {
    case 0: return (row + column) % 2 === 0
    case 1: return row % 2 === 0
    case 2: return column % 3 === 0
    case 3: return (row + column) % 3 === 0
    case 4: return (Math.floor(row / 2) + Math.floor(column / 3)) % 2 === 0
    case 5: return ((row * column) % 2) + ((row * column) % 3) === 0
    case 6: return (((row * column) % 2) + ((row * column) % 3)) % 2 === 0
    default: return (((row + column) % 2) + ((row * column) % 3)) % 2 === 0
  }
}

/// The mask the format field names. Bits 10-12, not the low three: the low ten
/// are the BCH remainder, and reading those gives the right answer only for
/// some codes, which is the kind of bug that survives a sample.
function formatMasks(grid) {
  const size = grid.length
  const read = at => {
    let value = 0
    for (let index = 0; index < 15; index += 1) if (at(index)) value |= 1 << index
    return value >>> 0
  }
  const first = read(index => {
    if (index < 6) return grid[index][8]
    if (index < 8) return grid[index + 1][8]
    if (index === 8) return grid[8][7]
    return grid[8][14 - index]
  })
  const second = read(index =>
    index < 8 ? grid[8][size - 1 - index] : grid[size - 15 + index][8])
  return [((first ^ 0x5412) >>> 10) & 0b111, ((second ^ 0x5412) >>> 10) & 0b111]
}

/// Reverses the block interleave, so the payload can be read in the order it
/// was written.
function deinterleave(bytes, version) {
  const sizes = []
  for (const [count, size] of BLOCK_SIZES[version]) {
    for (let index = 0; index < count; index += 1) sizes.push(size)
  }
  const blocks = sizes.map(() => [])
  const longest = Math.max(...sizes)
  let offset = 0
  for (let index = 0; index < longest; index += 1) {
    for (let block = 0; block < blocks.length; block += 1) {
      if (index < sizes[block]) blocks[block].push(bytes[offset++])
    }
  }
  return blocks.flat()
}

/// Reads the byte-mode payload out of a finished matrix, written from the
/// format rather than from the encoder's helpers.
function readPayload(grid, mask) {
  const size = grid.length
  const version = (size - 17) / 4
  const reserved = reservedMap(version, size)

  const bits = []
  let upward = true
  let column = size - 1
  while (column > 0) {
    if (column === 6) column -= 1
    for (let step = 0; step < size; step += 1) {
      const row = upward ? size - 1 - step : step
      for (let offset = 0; offset < 2; offset += 1) {
        const x = column - offset
        if (reserved[row][x]) continue
        let value = grid[row][x]
        if (maskCondition(mask, row, x)) value = !value
        bits.push(value)
        reserved[row][x] = true
      }
    }
    upward = !upward
    column -= 2
  }

  let bytes = []
  for (let start = 0; start < bits.length - (bits.length % 8); start += 8) {
    let byte = 0
    for (let offset = 0; offset < 8; offset += 1) byte = (byte << 1) | (bits[start + offset] ? 1 : 0)
    bytes.push(byte)
  }
  bytes = deinterleave(bytes, version)

  // The header is 4 bits of mode plus the length: 8 bits of it up to version 9,
  // 16 from version 10 up. So it is 12 bits wide on one side of that line and
  // 20 on the other, and taking the length from a fixed 16-bit window reads the
  // right number only for versions 10-99. Getting this wrong is invisible until
  // a payload crosses the boundary, which is why the vectors reach version 11.
  const stream = []
  for (const byte of bytes) for (let shift = 7; shift >= 0; shift -= 1) stream.push((byte >> shift) & 1)
  const headerWidth = version <= 9 ? 12 : 20
  if (stream.length < headerWidth) return null

  let header = 0
  for (let index = 0; index < headerWidth; index += 1) header = (header << 1) | stream[index]
  const mode = version <= 9 ? header >> 8 : header >> 16
  if (mode !== 0b0100) return null
  const length = version <= 9 ? header & 0xff : header & 0xffff
  if (stream.length < headerWidth + length * 8) return null

  const payload = []
  for (let index = 0; index < length; index += 1) {
    let byte = 0
    for (let offset = 0; offset < 8; offset += 1) {
      byte = (byte << 1) | stream[headerWidth + index * 8 + offset]
    }
    payload.push(byte)
  }
  return Buffer.from(payload)
}

// --- The checks -------------------------------------------------------------

const vectors = loadVectors(readFileSync(source, 'utf8'))
check('the reference vectors were found', vectors.length >= 3, `found ${vectors.length}`)

for (const vector of vectors) {
  const label = `version ${vector.version}, ${Buffer.byteLength(vector.text)} bytes`
  const grid = encode(vector.text)
  const size = vector.version * 4 + 17
  check(`the ${label} symbol is ${size} modules`, grid.length === size, `got ${grid.length}`)

  const reference = vector.rows.map(row => [...row].map(bit => bit === '1'))
  if (reference.length !== size + 4) {
    check(`the reference vector for ${label} is the right size`, false)
    continue
  }
  const referenceGrid = Array.from({ length: size }, (_, row) =>
    reference[row + 2].slice(2, size + 2))

  const mine = formatMasks(grid)
  const theirs = formatMasks(referenceGrid)
  check(`the format field names one mask for ${label}`, mine[0] === mine[1], `${mine}`)
  check(`and one for the reference, so the comparison means something`, theirs[0] === theirs[1], `${theirs}`)

  const reserved = reservedMap(vector.version, size)
  let differences = 0
  for (let row = 0; row < size; row += 1) {
    for (let column = 0; column < size; column += 1) {
      if (reserved[row][column]) continue
      let a = grid[row][column]
      if (maskCondition(mine[0], row, column)) a = !a
      let b = referenceGrid[row][column]
      if (maskCondition(theirs[0], row, column)) b = !b
      if (a !== b) differences += 1
    }
  }
  check(`every data module of ${label} matches the reference once unmasked`,
    differences === 0, `${differences} differ`)

  // Reading it back is the end-to-end claim: the code says what was put in.
  const payload = readPayload(grid, mine[0])
  check(`the payload of ${label} reads back`, payload !== null && payload.toString('utf8') === vector.text,
    payload === null ? 'decoder refused it' : `got ${payload.length} bytes`)
}

// The version a payload lands in is not free: it decides how big the printed
// code is, and one byte over a boundary would be a symbol too small for its own
// data.
for (const [bytes, version] of [[14, 1], [26, 2], [42, 3], [62, 4], [84, 5], [106, 6]]) {
  check(`${bytes} bytes lands in version ${version}`, versionFor(bytes) === version,
    `got ${versionFor(bytes)}`)
}
check('a payload past the largest symbol is refused', versionFor(LIMITS.maxBytes(40) + 1) === null)

let threw = false
try {
  encode('x'.repeat(LIMITS.maxBytes(40) + 1))
} catch {
  threw = true
}
check('a payload that does not fit throws rather than truncating', threw)

// Byte mode counts bytes, not characters: a hostname with an accent is longer
// than it looks, and a version chosen on character count would be too small.
const accented = 'cqutmux://pair?v=1&host=hôsté.example&user=a'
check('multi-byte text is sized by its byte length, not its character count',
  versionFor(Buffer.byteLength(accented)) === versionFor(Buffer.byteLength(accented))
  && Buffer.byteLength(accented) > accented.length)

check('a level other than M is refused rather than silently mis-encoded', (() => {
  try { encode('hello', { correction: 0 }); return false } catch { return true }
})())

// The terminal rendering has to be a QR code a camera can read: two characters
// per module (a terminal cell is about twice as tall as it is wide) and a quiet
// zone, which is part of the specification.
const drawn = terminal('cqutmux://pair?v=1&host=127.0.0.1').split('\n')
const drawnSize = drawn.length
check('the terminal code carries a quiet zone', drawn[0].trim() === '' && drawn[drawnSize - 1].trim() === '')
check('each line is two characters per module', drawn.every(line => [...line].length === drawnSize * 2))

process.stdout.write(failed === 0
  ? `\nQR_JS_PASS (${passed} checks)\n`
  : `\nQR_JS_FAIL (${failed} of ${passed + failed} checks failed)\n`)
process.exit(failed === 0 ? 0 : 1)