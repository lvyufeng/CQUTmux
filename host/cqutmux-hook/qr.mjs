// A QR encoder, for `cqutmux pair`.
//
// The same algorithm as `App/Shared/QRCode.swift`, and deliberately so — but it
// is a second implementation, which is the thing to be suspicious of. Two
// encoders that disagree produce a code that scans to a confidently wrong host,
// and the phone has no way to tell. So this is checked against the same
// reference matrices as the Swift one, from an independent encoder, rather than
// against the Swift one.
//
// Byte mode, error level M, versions 1 to 40. Returns a matrix of booleans,
// `true` being a dark module, with no quiet zone — the caller draws it.

const EC_M = 1; // the index level M occupies in the block table

// Data codewords and block layout per version at level M, from the spec's table.
// [ [count, dataCodewordsPerBlock], ... ], ecCodewordsPerBlock
const BLOCKS = {
  1: [[[1, 16]], 10],
  2: [[[1, 28]], 16],
  3: [[[1, 44]], 26],
  4: [[[2, 32]], 18],
  5: [[[2, 43]], 24],
  6: [[[4, 27]], 16],
  7: [[[4, 31]], 18],
  8: [[[2, 38], [2, 39]], 22],
  9: [[[3, 36], [2, 37]], 22],
  10: [[[4, 43], [1, 44]], 26],
  11: [[[1, 50], [4, 51]], 30],
  12: [[[6, 36], [2, 37]], 22],
  13: [[[8, 37], [1, 38]], 22],
  14: [[[4, 40], [5, 41]], 24],
  15: [[[5, 41], [5, 42]], 24],
  16: [[[7, 45], [3, 46]], 28],
  17: [[[10, 46], [1, 47]], 28],
  18: [[[9, 43], [4, 44]], 26],
  19: [[[3, 44], [11, 45]], 26],
  20: [[[3, 41], [13, 42]], 26],
  21: [[[17, 42]], 26],
  22: [[[17, 46]], 28],
  23: [[[4, 47], [14, 48]], 28],
  24: [[[6, 45], [14, 46]], 28],
  25: [[[8, 47], [13, 48]], 28],
  26: [[[19, 46], [4, 47]], 28],
  27: [[[22, 45], [3, 46]], 28],
  28: [[[3, 45], [23, 46]], 28],
  29: [[[21, 45], [7, 46]], 28],
  30: [[[19, 47], [10, 48]], 28],
  31: [[[2, 46], [29, 47]], 28],
  32: [[[10, 46], [23, 47]], 28],
  33: [[[14, 46], [21, 47]], 28],
  34: [[[14, 46], [23, 47]], 28],
  35: [[[12, 47], [26, 48]], 28],
  36: [[[6, 47], [34, 48]], 28],
  37: [[[29, 46], [14, 47]], 28],
  38: [[[13, 46], [32, 47]], 28],
  39: [[[40, 47], [7, 48]], 28],
  40: [[[18, 47], [31, 48]], 28],
}

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

function dataCodewords(version) {
  const [groups] = BLOCKS[version]
  return groups.reduce((sum, [count, size]) => sum + count * size, 0)
}

function maxBytes(version) {
  const overhead = 4 + (version <= 9 ? 8 : 16)
  return Math.max(0, Math.floor((dataCodewords(version) * 8 - overhead) / 8))
}

export function versionFor(byteCount) {
  for (let v = 1; v <= 40; v += 1) if (maxBytes(v) >= byteCount) return v
  return null
}

// --- Reed-Solomon over GF(256), primitive polynomial 0x11D ------------------

function gfMultiply(a, b) {
  if (a === 0 || b === 0) return 0
  let result = 0
  let x = a
  let y = b
  while (y > 0) {
    if (y & 1) result ^= x
    y >>= 1
    x <<= 1
    if (x & 0x100) x ^= 0x11d
  }
  return result & 0xff
}

function generatorPoly(degree) {
  let result = [1]
  let root = 1
  for (let step = 0; step < degree; step += 1) {
    const next = new Array(result.length + 1).fill(0)
    for (let index = 0; index < result.length; index += 1) {
      next[index] ^= result[index]
      next[index + 1] ^= gfMultiply(result[index], root)
    }
    result = next
    root = gfMultiply(root, 2)
  }
  return result.slice(1)
}

function errorCorrection(block, degree) {
  const generator = generatorPoly(degree)
  const remainder = new Array(degree).fill(0)
  for (const byte of block) {
    const factor = byte ^ remainder[0]
    remainder.shift()
    remainder.push(0)
    for (let index = 0; index < degree; index += 1) {
      remainder[index] ^= gfMultiply(generator[index], factor)
    }
  }
  return remainder
}

// --- Codewords --------------------------------------------------------------

function codewords(bytes, version) {
  const capacity = dataCodewords(version) * 8
  const bits = []
  const push = (value, width) => {
    for (let shift = width - 1; shift >= 0; shift -= 1) bits.push((value >> shift) & 1)
  }
  push(0b0100, 4)
  push(bytes.length, version <= 9 ? 8 : 16)
  for (const byte of bytes) push(byte, 8)

  const room = capacity - bits.length
  push(0, Math.min(4, Math.max(0, room)))
  while (bits.length % 8 !== 0) bits.push(0)

  let pad = 0
  while (bits.length < capacity) {
    push(pad % 2 === 0 ? 0xec : 0x11, 8)
    pad += 1
  }
  const out = []
  for (let index = 0; index < bits.length; index += 8) {
    let byte = 0
    for (let offset = 0; offset < 8; offset += 1) byte = (byte << 1) | bits[index + offset]
    out.push(byte)
  }
  return out
}

function interleave(data, version) {
  const [groups, ecPerBlock] = BLOCKS[version]
  const blocks = []
  let offset = 0
  for (const [count, size] of groups) {
    for (let index = 0; index < count; index += 1) {
      blocks.push(data.slice(offset, offset + size))
      offset += size
    }
  }
  const corrections = blocks.map(block => errorCorrection(block, ecPerBlock))
  const out = []
  const longest = Math.max(...blocks.map(block => block.length))
  for (let index = 0; index < longest; index += 1) {
    for (const block of blocks) if (index < block.length) out.push(block[index])
  }
  for (let index = 0; index < ecPerBlock; index += 1) {
    for (const correction of corrections) out.push(correction[index])
  }
  return out
}

// --- Modules ----------------------------------------------------------------

function blank(size) {
  return Array.from({ length: size }, () => new Array(size).fill(null))
}

function placeFinder(grid, row, column) {
  const size = grid.length
  for (let r = -1; r <= 7; r += 1) {
    for (let c = -1; c <= 7; c += 1) {
      const y = row + r
      const x = column + c
      if (y < 0 || y >= size || x < 0 || x >= size) continue
      // The 7x7 body is r,c in 0...6; treating the whole -1...7 span as the
      // finder darkens the separator, which leaves a reader nothing to measure
      // the pattern's edges against.
      const inBody = r >= 0 && r <= 6 && c >= 0 && c <= 6
      const onBorder = r === 0 || r === 6 || c === 0 || c === 6
      const inCore = r >= 2 && r <= 4 && c >= 2 && c <= 4
      grid[y][x] = inBody && (onBorder || inCore)
    }
  }
}

function placeTiming(grid) {
  const size = grid.length
  for (let index = 8; index < size - 8; index += 1) {
    if (grid[6][index] === null) grid[6][index] = index % 2 === 0
    if (grid[index][6] === null) grid[index][6] = index % 2 === 0
  }
}

function placeAlignment(grid, row, column) {
  for (let r = -2; r <= 2; r += 1) {
    for (let c = -2; c <= 2; c += 1) {
      const onBorder = r === -2 || r === 2 || c === -2 || c === 2
      const inCore = r === 0 && c === 0
      grid[row + r][column + c] = onBorder || inCore
    }
  }
}

function formatBits(mask) {
  // Error level M is indicator 00.
  const data = (0b00 << 3) | mask
  let remainder = data
  for (let step = 0; step < 10; step += 1) {
    remainder = (remainder << 1) ^ (((remainder >> 9) & 1) * 0x537)
  }
  return (((data << 10) | remainder) ^ 0x5412) >>> 0
}

function placeFormat(grid, format) {
  const size = grid.length
  for (let index = 0; index < 15; index += 1) {
    const bit = ((format >> index) & 1) === 1
    if (index < 6) grid[index][8] = bit
    else if (index < 8) grid[index + 1][8] = bit
    else if (index === 8) grid[8][7] = bit
    else grid[8][14 - index] = bit

    if (index < 8) grid[8][size - 1 - index] = bit
    else grid[size - 15 + index][8] = bit
  }
  grid[size - 8][8] = true
}

function placeVersion(grid, version) {
  const size = grid.length
  let remainder = version
  for (let step = 0; step < 12; step += 1) {
    remainder = (remainder << 1) ^ (((remainder >> 11) & 1) * 0x1f25)
  }
  const bits = (version << 12) | remainder
  for (let index = 0; index < 18; index += 1) {
    const bit = ((bits >> index) & 1) === 1
    const row = Math.floor(index / 3)
    const column = index % 3
    grid[size - 11 + column][row] = bit
    grid[row][size - 11 + column] = bit
  }
}

function placeData(grid, reserved, stream) {
  const size = grid.length
  const bits = []
  for (const byte of stream) {
    for (let shift = 7; shift >= 0; shift -= 1) bits.push((byte >> shift) & 1)
  }
  // Its own copy of the map: `reserved` has to stay the record of which modules
  // are function patterns, because masking and the penalty both need that same
  // answer afterwards. Marking cells filled here would leave "reserved" meaning
  // "every cell" by the time `applyMask` ran, and the mask would be applied to
  // nothing — which is a code that looks plausible, chooses a mask on the wrong
  // evidence, and cannot be read back.
  const filled = reserved.map(row => [...row])
  let index = 0
  let upward = true
  let column = size - 1
  while (column > 0) {
    if (column === 6) column -= 1
    for (let step = 0; step < size; step += 1) {
      const row = upward ? size - 1 - step : step
      for (let offset = 0; offset < 2; offset += 1) {
        const x = column - offset
        if (filled[row][x]) continue
        grid[row][x] = index < bits.length ? bits[index] === 1 : false
        filled[row][x] = true
        index += 1
      }
    }
    upward = !upward
    column -= 2
  }
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

function applyMask(mask, grid, reserved) {
  for (let row = 0; row < grid.length; row += 1) {
    for (let column = 0; column < grid.length; column += 1) {
      if (!reserved[row][column] && maskCondition(mask, row, column)) {
        grid[row][column] = !grid[row][column]
      }
    }
  }
}

function penalty(grid) {
  const size = grid.length
  let score = 0

  for (let line = 0; line < size; line += 1) {
    let runRow = 1
    let runColumn = 1
    for (let index = 1; index < size; index += 1) {
      runRow = grid[line][index] === grid[line][index - 1] ? runRow + 1 : 1
      if (runRow === 5) score += 3
      else if (runRow > 5) score += 1
      runColumn = grid[index][line] === grid[index - 1][line] ? runColumn + 1 : 1
      if (runColumn === 5) score += 3
      else if (runColumn > 5) score += 1
    }
  }

  for (let row = 0; row < size - 1; row += 1) {
    for (let column = 0; column < size - 1; column += 1) {
      const value = grid[row][column]
      if (grid[row][column + 1] === value && grid[row + 1][column] === value
          && grid[row + 1][column + 1] === value) score += 3
    }
  }

  const pattern = [true, false, true, true, true, false, true, false, false, false, false]
  const reversed = [...pattern].reverse()
  for (let row = 0; row < size; row += 1) {
    for (let column = 0; column <= size - 11; column += 1) {
      let forward = true
      let backward = true
      for (let offset = 0; offset < 11; offset += 1) {
        const value = grid[row][column + offset]
        if (value !== pattern[offset]) forward = false
        if (value !== reversed[offset]) backward = false
      }
      if (forward || backward) score += 40
    }
  }
  for (let column = 0; column < size; column += 1) {
    for (let row = 0; row <= size - 11; row += 1) {
      let forward = true
      let backward = true
      for (let offset = 0; offset < 11; offset += 1) {
        const value = grid[row + offset][column]
        if (value !== pattern[offset]) forward = false
        if (value !== reversed[offset]) backward = false
      }
      if (forward || backward) score += 40
    }
  }

  const dark = grid.flat().filter(Boolean).length
  const percent = Math.floor((dark * 100) / (size * size))
  const previous = Math.floor(percent / 5) * 5
  score += (Math.min(Math.abs(previous - 50), Math.abs(previous + 5 - 50)) / 5) * 10
  return score
}

function bestMask(grid, reserved) {
  let best = 0
  let bestScore = Infinity
  for (let mask = 0; mask < 8; mask += 1) {
    // The reserved map is carried in rather than re-derived: after the data is
    // placed every cell is non-null, so "null means reserved" is false exactly
    // when this needs it, and the mask would be applied to nothing.
    const candidate = grid.map(row => [...row])
    applyMask(mask, candidate, reserved)
    placeFormat(candidate, formatBits(mask))
    const score = penalty(candidate.map(row => row.map(Boolean)))
    if (score < bestScore) {
      bestScore = score
      best = mask
    }
  }
  return best
}

/**
 * Encodes `text` and returns the modules, `true` being dark.
 *
 * Throws when the text does not fit in a version-40 symbol, rather than
 * emitting a truncated code.
 */
export function encode(text, { correction = EC_M } = {}) {
  if (correction !== EC_M) throw new Error('only error correction level M is implemented')
  const bytes = Array.from(Buffer.from(text, 'utf8'))
  const version = versionFor(bytes.length)
  if (version === null) {
    throw new Error(`payload is ${bytes.length} bytes; the largest this encodes is ${maxBytes(40)}`)
  }

  const size = version * 4 + 17
  const grid = blank(size)

  placeFinder(grid, 0, 0)
  placeFinder(grid, 0, size - 7)
  placeFinder(grid, size - 7, 0)
  placeTiming(grid)
  const centres = ALIGNMENT[version]
  for (const row of centres) {
    for (const column of centres) {
      // Placed at every centre but those overlapping a finder. Skipping ones
      // whose module is already set looks right and is wrong from version 7 on,
      // where the coordinate list includes centres sitting on the timing lines.
      if ((row < 9 && column < 9) || (row < 9 && column > size - 10)
          || (row > size - 10 && column < 9)) continue
      placeAlignment(grid, row, column)
    }
  }
  placeFormat(grid, 0)
  if (version >= 7) placeVersion(grid, version)

  const reserved = grid.map(row => row.map(cell => cell !== null))
  const stream = interleave(codewords(bytes, version), version)
  placeData(grid, reserved, stream)

  const mask = bestMask(grid, reserved)
  applyMask(mask, grid, reserved)
  placeFormat(grid, formatBits(mask))
  return grid.map(row => row.map(cell => cell === true))
}

/**
 * The code drawn for a terminal, two characters per module.
 *
 * Two rather than one because a terminal cell is about twice as tall as it is
 * wide, so one per module draws a code stretched vertically that often will not
 * scan. The quiet zone is part of the specification, not decoration.
 */
export function terminal(text, { border = 2 } = {}) {
  const grid = encode(text)
  const size = grid.length + border * 2
  const lines = []
  for (let row = 0; row < size; row += 1) {
    let line = ''
    for (let column = 0; column < size; column += 1) {
      const inside = row >= border && column >= border && row < size - border && column < size - border
      const dark = inside && grid[row - border][column - border]
      line += dark ? '██' : '  '
    }
    lines.push(line)
  }
  return lines.join('\n')
}

export const LIMITS = { maxBytes }