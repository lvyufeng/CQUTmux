import Foundation

/// A QR encoder, for the half of Easy Pair that has to be looked at with a
/// camera.
///
/// Written rather than linked because the payload is a few hundred bytes of
/// text and pulling a package in for it would be more surface than the problem
/// has. Byte mode only, one error-correction level, versions 1 to 40 — the
/// whole of what a URL-sized string needs.
///
/// The failure mode this guards against is the one a QR code has: a code that
/// scans to *something* is far more common than one that does not scan at all,
/// and a payload that is one bit wrong yields a confident wrong host. That is
/// why `scripts/qr-check.sh` compares whole matrices against an independent
/// encoder rather than checking that the shape looks right.
///
/// Foundation-only, so the checks run without a simulator.
enum QRCode {
    enum Error: Swift.Error, Equatable {
        case tooLong(limit: Int)
    }

    /// The payload is a URL, and a URL that fails to decode is a failed setup,
    /// so the middle level: about 15% recoverable, at roughly two thirds the
    /// data capacity of the lowest. Higher levels cost so much capacity that a
    /// longer payload would jump a version and get *denser* on screen.
    enum Correction: String, CaseIterable {
        case low, medium, quartile, high
    }

    /// The modules, without a quiet zone — the caller knows its own margins and
    /// a renderer adding four more is a different bug from one adding none.
    ///
    /// `true` is a dark module.
    static func encode(_ text: String, correction: Correction = .medium) throws -> [[Bool]] {
        let data = Array(text.utf8)
        guard let version = version(forByteCount: data.count, correction: correction) else {
            // The caller is told the limit rather than just that it failed: the
            // only useful thing to do about it is shorten the payload.
            throw Error.tooLong(limit: maxByteCount(version: 40, correction: correction))
        }
        return matrix(for: data, version: version, correction: correction)
    }

    /// The largest payload the given version and level can hold, in bytes.
    static func maxByteCount(version: Int, correction: Correction) -> Int {
        let capacityBits = dataCodewords(version: version, correction: correction) * 8
        let overhead = 4 + (version <= 9 ? 8 : 16)
        return max(0, (capacityBits - overhead) / 8)
    }

    /// The smallest version the payload fits in, or nil if none does.
    static func version(forByteCount count: Int, correction: Correction) -> Int? {
        (1...40).first { maxByteCount(version: $0, correction: correction) >= count }
    }

    /// The code drawn for a terminal, two characters per module.
    ///
    /// Two per module rather than one because a terminal cell is roughly twice
    /// as tall as it is wide, so one character per module draws a code that is
    /// stretched vertically and often will not scan. The quiet zone is four
    /// modules: it is part of the specification, not decoration, and a code
    /// flush against other text is the most common reason one does not read.
    static func terminal(_ grid: [[Bool]], border: Int = 2) -> String {
        let size = grid.count + border * 2
        // Half-block characters would be twice the resolution, but they also
        // make the output unreadable in a terminal without a font that has
        // them; reproducibility matters more here than density.
        return (0..<size).map { row in
            (0..<size).map { column -> String in
                let inside = row >= border && column >= border
                    && row < size - border && column < size - border
                let dark = inside && grid[row - border][column - border]
                return dark ? "\u{2588}\u{2588}" : "  "
            }.joined()
        }.joined(separator: "\n")
    }

    // MARK: - Codewords

    /// A big-endian bit accumulator. QR fields are not byte-aligned, so the
    /// only sane representation is a bit list.
    private struct BitBuffer {
        private(set) var bits: [Bool] = []

        var count: Int { bits.count }

        mutating func append(_ value: UInt32, _ width: Int) {
            guard width > 0 else { return }
            for shift in stride(from: width - 1, through: 0, by: -1) {
                bits.append((value >> UInt32(shift)) & 1 == 1)
            }
        }

        var bytes: [UInt8] {
            stride(from: 0, to: bits.count, by: 8).map { start in
                var byte: UInt8 = 0
                for offset in 0..<8 where start + offset < bits.count {
                    byte = (byte << 1) | (bits[start + offset] ? 1 : 0)
                }
                return byte
            }
        }
    }

    /// Byte mode, with the terminator and padding the spec requires.
    private static func codewords(_ data: [UInt8], version: Int, correction: Correction) -> [UInt8] {
        let capacity = dataCodewords(version: version, correction: correction) * 8
        var bits = BitBuffer()
        bits.append(0b0100, 4)                      // byte mode
        bits.append(UInt32(data.count), version <= 9 ? 8 : 16)
        for byte in data { bits.append(UInt32(byte), 8) }

        // Terminator, up to four zero bits, then pad to a byte boundary.
        let room = capacity - bits.count
        bits.append(0, min(4, max(0, room)))
        while bits.count % 8 != 0 { bits.append(0, 1) }

        // The two alternating pad bytes, which exist so the mask evaluation has
        // something non-trivial to score rather than a run of zeros.
        var pad = 0
        while bits.count < capacity {
            bits.append(pad % 2 == 0 ? 0xEC : 0x11, 8)
            pad += 1
        }
        return bits.bytes
    }

    /// Reed-Solomon generator polynomial of the given degree, highest term
    /// first with the leading 1 omitted (it is implied).
    private static func generatorPoly(_ degree: Int) -> [UInt8] {
        var result: [UInt8] = [1]
        var root: UInt8 = 1
        for _ in 0..<degree {
            // Multiply the running polynomial by (x - α^i).
            var next = [UInt8](repeating: 0, count: result.count + 1)
            for (index, coefficient) in result.enumerated() {
                next[index] ^= coefficient
                next[index + 1] ^= gfMultiply(coefficient, root)
            }
            result = next
            root = gfMultiply(root, 2)
        }
        return Array(result.dropFirst())
    }

    /// Multiplication in GF(256) with the QR primitive polynomial 0x11D.
    private static func gfMultiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        guard a != 0, b != 0 else { return 0 }
        var result: UInt16 = 0
        var x = UInt16(a)
        var y = UInt16(b)
        while y > 0 {
            if y & 1 == 1 { result ^= x }
            y >>= 1
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x11D }
        }
        return UInt8(result & 0xFF)
    }

    private static func errorCorrection(_ block: [UInt8], degree: Int) -> [UInt8] {
        let generator = generatorPoly(degree)
        var remainder = [UInt8](repeating: 0, count: degree)
        for byte in block {
            let factor = byte ^ remainder[0]
            remainder.removeFirst()
            remainder.append(0)
            for index in 0..<degree {
                remainder[index] ^= gfMultiply(generator[index], factor)
            }
        }
        return remainder
    }

    // MARK: - Block structure

    /// Total data codewords for a version at a level.
    private static func dataCodewords(version: Int, correction: Correction) -> Int {
        structure(version: version, correction: correction).dataCodewords
    }

    fileprivate struct BlockGroup {
        var count: Int
        var dataCodewords: Int
        var ecPerBlock: Int
    }

    fileprivate struct Structure {
        var groups: [BlockGroup]
        var dataCodewords: Int
    }

    /// Splits data codewords into the blocks the spec prescribes, computes each
    /// block's error correction, and interleaves.
    ///
    /// The interleaving is where a subtle mistake hides: take the first
    /// codeword of every block, then the second of every block, and so on. A
    /// single-block implementation gets this right by accident and breaks the
    /// moment the payload needs a second block, which is exactly when nobody is
    /// looking at the small cases any more.
    private static func interleaved(_ data: [UInt8], version: Int, correction: Correction) -> [UInt8] {
        let structure = structure(version: version, correction: correction)
        var blocks: [[UInt8]] = []
        var offset = 0
        for group in structure.groups {
            for _ in 0..<group.count {
                let end = min(offset + group.dataCodewords, data.count)
                blocks.append(Array(data[offset..<end]))
                offset = end
            }
        }

        let degree = structure.groups[0].ecPerBlock
        let corrections = blocks.map { errorCorrection($0, degree: degree) }

        var out: [UInt8] = []
        let longest = blocks.map(\.count).max() ?? 0
        for index in 0..<longest {
            for block in blocks where index < block.count {
                out.append(block[index])
            }
        }
        for index in 0..<degree {
            for correction in corrections {
                out.append(correction[index])
            }
        }
        return out
    }

    // MARK: - Modules

    /// Builds the matrix: function patterns, then data, then the mask.
    private static func matrix(for data: [UInt8], version: Int, correction: Correction) -> [[Bool]] {
        let size = version * 4 + 17
        var grid = [[Bool?]](repeating: [Bool?](repeating: nil, count: size), count: size)

        placeFinder(&grid, row: 0, column: 0)
        placeFinder(&grid, row: 0, column: size - 7)
        placeFinder(&grid, row: size - 7, column: 0)
        placeTiming(&grid)
        // Placed at every centre except those overlapping a finder. The obvious
        // guard — "only where the module is still empty" — is wrong, and wrong
        // only for some versions: the timing pattern is laid down first, and
        // from version 7 the coordinate list includes centres that sit *on* it
        // (6, 30) at version 11, for instance. Those are placed anyway, and the
        // alignment pattern's middle row agrees with the timing alternation
        // there, so nothing is lost. Skipping them leaves ten data modules
        // unplaced and shifts the rest, which reads as a code that scans to
        // garbage rather than as a missing pattern.
        for row in alignmentCentres(version: version) {
            for column in alignmentCentres(version: version) {
                if (row < 9 && column < 9) || (row < 9 && column > size - 10)
                    || (row > size - 10 && column < 9) { continue }
                placeAlignment(&grid, row: row, column: column)
            }
        }
        // Reserve the format areas with a placeholder so the data placement
        // skips them; the real bits are written once the mask is chosen.
        let formatPlaceholder: UInt32 = 0
        placeFormat(&grid, format: formatPlaceholder)
        let versionBits = version >= 7
        if versionBits { placeVersion(&grid, version: version) }

        // Which modules are function patterns. Kept as its own value rather than
        // re-derived later: after `placeData` every cell is non-nil, so
        // "non-nil means reserved" stops being true exactly when the masking
        // code needs it. Deriving it there is how the mask came to be applied
        // to nothing at all — the eight candidates differed only in their
        // format bits, and the one chosen was chosen on the wrong evidence.
        let reserved = grid.map { $0.map { $0 != nil } }

        let codewords = interleaved(codewords(data, version: version, correction: correction),
                                    version: version, correction: correction)
        var placed = grid
        var placedReserved = reserved
        placeData(&placed, reserved: &placedReserved, codewords: codewords)

        let mask = bestMask(placed, reserved: reserved, version: version, correction: correction)
        apply(mask: mask, to: &placed, reserved: reserved)
        placeFormat(&placed, format: formatBits(correction: correction, mask: mask))
        return placed.map { $0.map { $0 ?? false } }
    }

    private static func placeFinder(_ grid: inout [[Bool?]], row: Int, column: Int) {
        for r in -1...7 {
            for c in -1...7 {
                let y = row + r
                let x = column + c
                guard y >= 0, y < grid.count, x >= 0, x < grid.count else { continue }
                // The 7x7 body is r,c in 0...6. Writing this as though the
                // whole -1...7 span were the finder makes the enclosing
                // separator dark along its top row and left column, which
                // leaves the pattern looking right and gives a reader nothing
                // to measure the finder's edges against.
                let inBody = (0...6).contains(r) && (0...6).contains(c)
                let onBorder = r == 0 || r == 6 || c == 0 || c == 6
                let inCore = (2...4).contains(r) && (2...4).contains(c)
                grid[y][x] = inBody && (onBorder || inCore)
            }
        }
    }

    private static func placeTiming(_ grid: inout [[Bool?]]) {
        let size = grid.count
        for index in 8..<(size - 8) {
            // Only where a finder's quiet separation has not already claimed a
            // value — the timing row runs between the finders, over the same
            // coordinates their format areas sit in.
            if grid[6][index] == nil { grid[6][index] = index % 2 == 0 }
            if grid[index][6] == nil { grid[index][6] = index % 2 == 0 }
        }
    }

    private static func placeAlignment(_ grid: inout [[Bool?]], row: Int, column: Int) {
        for r in -2...2 {
            for c in -2...2 {
                let onBorder = r == -2 || r == 2 || c == -2 || c == 2
                let inCore = r == 0 && c == 0
                grid[row + r][column + c] = onBorder || inCore
            }
        }
    }

    /// Format information: two copies, masked with 0x5412, the low bits
    /// distributed through the finder separation.
    private static func placeFormat(_ grid: inout [[Bool?]], format: UInt32) {
        let size = grid.count
        for index in 0..<15 {
            let bit = (format >> UInt32(index)) & 1 == 1
            // First copy, around the top-left finder.
            if index < 6 {
                grid[index][8] = bit
            } else if index < 8 {
                grid[index + 1][8] = bit
            } else if index == 8 {
                grid[8][7] = bit
            } else {
                grid[8][14 - index] = bit
            }
            // Second copy, split between the other two finders.
            if index < 8 {
                grid[8][size - 1 - index] = bit
            } else {
                grid[size - 15 + index][8] = bit
            }
        }
        // The dark module, always on, at the corner of the bottom-left finder.
        grid[size - 8][8] = true
    }

    private static func placeVersion(_ grid: inout [[Bool?]], version: Int) {
        let size = grid.count
        var remainder = UInt32(version)
        for _ in 0..<12 {
            remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25)
        }
        let bits = (UInt32(version) << 12) | remainder
        for index in 0..<18 {
            let bit = (bits >> UInt32(index)) & 1 == 1
            let row = index / 3
            let column = index % 3
            grid[size - 11 + column][row] = bit
            grid[row][size - 11 + column] = bit
        }
    }

    private static func placeData(_ grid: inout [[Bool?]], reserved: inout [[Bool]], codewords: [UInt8]) {
        let size = grid.count
        var bits: [Bool] = []
        for byte in codewords {
            for shift in stride(from: 7, through: 0, by: -1) {
                bits.append((byte >> UInt8(shift)) & 1 == 1)
            }
        }

        var index = 0
        var upward = true
        var column = size - 1
        while column > 0 {
            // Column 6 is the vertical timing pattern, so the two-module column
            // pair skips it.
            if column == 6 { column -= 1 }
            for step in 0..<size {
                let row = upward ? size - 1 - step : step
                for offset in 0..<2 {
                    let x = column - offset
                    if reserved[row][x] { continue }
                    grid[row][x] = index < bits.count ? bits[index] : false
                    reserved[row][x] = true
                    index += 1
                }
            }
            upward.toggle()
            column -= 2
        }
    }

    // MARK: - Masking

    private static func apply(mask: Int, to grid: inout [[Bool?]], reserved: [[Bool]]) {
        for row in 0..<grid.count {
            for column in 0..<grid.count where !reserved[row][column] {
                if maskCondition(mask, row: row, column: column) {
                    grid[row][column] = !(grid[row][column] ?? false)
                }
            }
        }
    }

    private static func maskCondition(_ mask: Int, row: Int, column: Int) -> Bool {
        switch mask {
        case 0: return (row + column) % 2 == 0
        case 1: return row % 2 == 0
        case 2: return column % 3 == 0
        case 3: return (row + column) % 3 == 0
        case 4: return (row / 2 + column / 3) % 2 == 0
        case 5: return (row * column) % 2 + (row * column) % 3 == 0
        case 6: return ((row * column) % 2 + (row * column) % 3) % 2 == 0
        default: return ((row + column) % 2 + (row * column) % 3) % 2 == 0
        }
    }

    /// The four penalty rules from the spec, summed. The mask with the lowest
    /// score is the one a reader is least likely to misjudge.
    private static func penalty(_ grid: [[Bool]]) -> Int {
        let size = grid.count
        var score = 0

        // Rule 1: runs of the same colour, in rows and in columns.
        for line in 0..<size {
            var runRow = 1
            var runColumn = 1
            for index in 1..<size {
                runRow = grid[line][index] == grid[line][index - 1] ? runRow + 1 : 1
                if runRow == 5 { score += 3 } else if runRow > 5 { score += 1 }
                runColumn = grid[index][line] == grid[index - 1][line] ? runColumn + 1 : 1
                if runColumn == 5 { score += 3 } else if runColumn > 5 { score += 1 }
            }
        }

        // Rule 2: every 2x2 block of one colour.
        for row in 0..<(size - 1) {
            for column in 0..<(size - 1) {
                let value = grid[row][column]
                if grid[row][column + 1] == value,
                   grid[row + 1][column] == value,
                   grid[row + 1][column + 1] == value {
                    score += 3
                }
            }
        }

        // Rule 3: the finder-like pattern, which a reader mistakes for a real
        // finder. Both orientations of the separator arrangement.
        let pattern = [true, false, true, true, true, false, true,
                       false, false, false, false]
        let reversed = Array(pattern.reversed())
        for row in 0..<size {
            for column in 0...(size - 11) {
                var horizontal = true
                var horizontalReversed = true
                for offset in 0..<11 {
                    let value = grid[row][column + offset]
                    if value != pattern[offset] { horizontal = false }
                    if value != reversed[offset] { horizontalReversed = false }
                }
                if horizontal || horizontalReversed { score += 40 }
            }
        }
        for column in 0..<size {
            for row in 0...(size - 11) {
                var vertical = true
                var verticalReversed = true
                for offset in 0..<11 {
                    let value = grid[row + offset][column]
                    if value != pattern[offset] { vertical = false }
                    if value != reversed[offset] { verticalReversed = false }
                }
                if vertical || verticalReversed { score += 40 }
            }
        }

        // Rule 4: the deviation of the dark-module proportion from one half.
        let dark = grid.flatMap { $0 }.filter { $0 }.count
        let percent = dark * 100 / (size * size)
        let previous = (percent / 5) * 5
        score += min(abs(previous - 50), abs(previous + 5 - 50)) / 5 * 10
        return score
    }

    private static func bestMask(
        _ grid: [[Bool?]],
        reserved: [[Bool]],
        version: Int,
        correction: Correction
    ) -> Int {
        var best = 0
        var bestScore = Int.max
        for mask in 0..<8 {
            var candidate = grid
            apply(mask: mask, to: &candidate, reserved: reserved)
            placeFormat(&candidate, format: formatBits(correction: correction, mask: mask))
            let score = penalty(candidate.map { $0.map { $0 ?? false } })
            if score < bestScore {
                bestScore = score
                best = mask
            }
        }
        return best
    }

    /// The 15-bit format field: five data bits, BCH(15,5), then the 0x5412 mask.
    private static func formatBits(correction: Correction, mask: Int) -> UInt32 {
        let indicator: UInt32 = switch correction {
        case .low: 0b01
        case .medium: 0b00
        case .quartile: 0b11
        case .high: 0b10
        }
        let data = (indicator << 3) | UInt32(mask)
        var remainder = data
        for _ in 0..<10 {
            remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537)
        }
        return ((data << 10) | remainder) ^ 0x5412
    }
}

// MARK: - The tables

extension QRCode {
    /// Alignment pattern centres, per version.
    private static func alignmentCentres(version: Int) -> [Int] {
        guard version > 1 else { return [] }
        let table: [Int: [Int]] = [
            2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34],
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
        ]
        return table[version] ?? []
    }

    /// The block layout per version at level M, transcribed from the spec's table
    /// (ISO/IEC 18004 table 9).
    ///
    /// Only level M, because that is the only level this app encodes at, and a
    /// table filled in for levels nobody uses is a table with three quarters of
    /// its entries never checked. `structure` refuses the others rather than
    /// silently answering with M's numbers, which would produce a code that
    /// decodes to nothing and looks fine.
    fileprivate static func structure(version: Int, correction: Correction) -> Structure {
        guard correction == .medium else { return Structure(groups: [], dataCodewords: 0) }
        let table: [Int: ([(Int, Int)], Int)] = [
            1: ([(1, 16)], 10),
            2: ([(1, 28)], 16),
            3: ([(1, 44)], 26),
            4: ([(2, 32)], 18),
            5: ([(2, 43)], 24),
            6: ([(4, 27)], 16),
            7: ([(4, 31)], 18),
            8: ([(2, 38), (2, 39)], 22),
            9: ([(3, 36), (2, 37)], 22),
            10: ([(4, 43), (1, 44)], 26),
            11: ([(1, 50), (4, 51)], 30),
            12: ([(6, 36), (2, 37)], 22),
            13: ([(8, 37), (1, 38)], 22),
            14: ([(4, 40), (5, 41)], 24),
            15: ([(5, 41), (5, 42)], 24),
            16: ([(7, 45), (3, 46)], 28),
            17: ([(10, 46), (1, 47)], 28),
            18: ([(9, 43), (4, 44)], 26),
            19: ([(3, 44), (11, 45)], 26),
            20: ([(3, 41), (13, 42)], 26),
            21: ([(17, 42)], 26),
            22: ([(17, 46)], 28),
            23: ([(4, 47), (14, 48)], 28),
            24: ([(6, 45), (14, 46)], 28),
            25: ([(8, 47), (13, 48)], 28),
            26: ([(19, 46), (4, 47)], 28),
            27: ([(22, 45), (3, 46)], 28),
            28: ([(3, 45), (23, 46)], 28),
            29: ([(21, 45), (7, 46)], 28),
            30: ([(19, 47), (10, 48)], 28),
            31: ([(2, 46), (29, 47)], 28),
            32: ([(10, 46), (23, 47)], 28),
            33: ([(14, 46), (21, 47)], 28),
            34: ([(14, 46), (23, 47)], 28),
            35: ([(12, 47), (26, 48)], 28),
            36: ([(6, 47), (34, 48)], 28),
            37: ([(29, 46), (14, 47)], 28),
            38: ([(13, 46), (32, 47)], 28),
            39: ([(40, 47), (7, 48)], 28),
            40: ([(18, 47), (31, 48)], 28),
        ]
        guard let entry = table[version] else { return Structure(groups: [], dataCodewords: 0) }
        let groups = entry.0.map { BlockGroup(count: $0.0, dataCodewords: $0.1, ecPerBlock: entry.1) }
        return Structure(groups: groups, dataCodewords: entry.0.reduce(0) { $0 + $1.0 * $1.1 })
    }
}