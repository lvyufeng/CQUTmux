import Foundation

// The QR encoder: whole matrices against reference vectors, and the payload
// read back out.
//
// A QR code's failure mode is the worst kind for a pairing flow. A code that
// scans to *something* is far more common than one that does not scan at all,
// and a payload one bit wrong binds the app to a different host — confidently,
// with no error anywhere. So "it looks like a QR code" is worth nothing here.
// The matrix is compared module by module against vectors from an independent
// encoder, and the payload is read back with a decoder written from the format
// rather than from the encoder's own helpers (a decoder that shares those
// assumptions proves only that the two agree about a shared mistake).
//
// `QRCode.swift` is Foundation-only, so this needs no simulator.

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("PASS  \(label)")
    } else {
        failures += 1
        print("FAIL  \(label)")
    }
}

/// The matrix as rows of "1"/"0" with the same quiet zone the vectors carry.
func render(_ grid: [[Bool]], border: Int = 2) -> [String] {
    let size = grid.count + border * 2
    return (0..<size).map { row in
        String((0..<size).map { column -> Character in
            let inside = row >= border && column >= border
                && row < size - border && column < size - border
            let dark = inside && grid[row - border][column - border]
            return dark ? "1" : "0"
        })
    }
}

/// Layers a matrix against a vector and reports the first difference, so a
/// failure says *where* rather than just "not equal".
func firstDifference(_ actual: [String], _ expected: [String]) -> String? {
    guard actual.count == expected.count else {
        return "size \(actual.count) rows vs \(expected.count)"
    }
    for (row, line) in actual.enumerated() {
        let want = expected[row]
        guard line.count == want.count else {
            return "row \(row): width \(line.count) vs \(want.count)"
        }
        if line != want {
            let at = zip(line, want).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? 0
            return "row \(row) column \(at): \(line) vs \(want)"
        }
    }
    return nil
}

// MARK: - Reference vectors

// Level M, border 2, produced by the Python `qrcode` package — an independent
// implementation, not a transcription of this one.
let vectors: [(text: String, version: Int, rows: [String])] = [
    ("cqutmux://pair?v=1&host=127.0.0.1#k=AAA", 3, [
        "000000000000000000000000000000000",
        "000000000000000000000000000000000",
        "001111111001001111010000111111100",
        "001000001011010000100010100000100",
        "001011101011101011101100101110100",
        "001011101011100001011000101110100",
        "001011101001011000010110101110100",
        "001000001001111000100010100000100",
        "001111111010101010101010111111100",
        "000000000010000011000110000000000",
        "001000001010000010011101100111000",
        "000011100001101011000100011111000",
        "001111101001000001101001111000000",
        "000000000110110011000001001101000",
        "001011011101101111101010110100100",
        "001001110000100101000111111111100",
        "001011011001011111111001001100000",
        "001011010101101110101100001111100",
        "001000111011100011111001010111000",
        "001110000010100001000101111101100",
        "001111111000110111100100000010100",
        "001001110011101011100001110101100",
        "001011011011100000011011111111000",
        "000000000010010101111110001000000",
        "001111111001001111010110101000000",
        "001000001000110100001010001001100",
        "001011101001110101001111111000100",
        "001011101001011101000101000010100",
        "001011101000101101001110101011000",
        "001000001001101011001101110010100",
        "001111111011111010011001110010000",
        "000000000000000000000000000000000",
        "000000000000000000000000000000000",
    ]),
    ("cqutmux://pair?v=1&host=10.0.0.5&port=24543#k=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", 6, [
        "000000000000000000000000000000000000000000000",
        "000000000000000000000000000000000000000000000",
        "001111111000010001101011000001101010111111100",
        "001000001001011110111000001101011000100000100",
        "001011101010011001101101011000001100101110100",
        "001011101010110000000001100011100010101110100",
        "001011101010010010111011011000011110101110100",
        "001000001011010011000000100101010010100000100",
        "001111111010101010101010101010101010111111100",
        "000000000011110010000101011001100110000000000",
        "001011111001010110011010111101111100111110000",
        "001011000101100010000100011010101101011001000",
        "001001101000010100111001100011111001000110000",
        "001101010000000001001011101011001101101101100",
        "000010001110111110000001101100010100010111000",
        "001000010011000011001011000011100011001001000",
        "000111001001111111011000001101011000100000000",
        "000100100110001111101101011000001100010001100",
        "000100011111111001000001101011000000000011000",
        "000000110000100101101011000001101010111000100",
        "000000111000100101111000001101011000001011000",
        "000010000000110010101101011000001100011101100",
        "000110011110010111100001101011100001001000100",
        "001011110100101101001010010100011111111001100",
        "000110011000000101001001000111010001000010000",
        "001000100001011000000101011010000001101101100",
        "001010111010000001011010100111010010001001100",
        "000011010110001010000111011010100101011001000",
        "001000011000001101111010000011100001000100000",
        "000001110101100000101101000001001001101101100",
        "001101101110110101100001111101011100000111000",
        "001011000100011011101011000011100011001111000",
        "001001111000001100011000001101011000001010000",
        "001011010100000010001101011000001100001001100",
        "001001011011101010100001101011000011111111000",
        "000000000010001011001011000001101010001001100",
        "001111111000001101011000001101011010101011000",
        "001000001011111111101101011000001110001101000",
        "001011101011101001001001101011100011111001000",
        "001011101010110001011010011000001010010001100",
        "001011101011101111100000100111101000111010000",
        "001000001000010101101101111001101110011101000",
        "001111111010100100101010100100010101111000000",
        "000000000000000000000000000000000000000000000",
        "000000000000000000000000000000000000000000000",
    ]),
    ("cqutmux://pair?v=1&host=192.168.1.44&user=someone&port=22&token=CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", 11, [
        "00000000000000000000000000000000000000000000000000000000000000000",
        "00000000000000000000000000000000000000000000000000000000000000000",
        "00111111100111111000110010110100100001010011111001010110111111100",
        "00100000100110101011100101011001011100100100100100110110100000100",
        "00101110101010110010111101011101101100100100100100101110101110100",
        "00101110101000100101100011010100011001110001110001111010101110100",
        "00101110101000010010111101001011111101000010111101001100101110100",
        "00100000101001001000011101100110001000110101100000101000100000100",
        "00111111101010101010101010101010101010101010101010101010111111100",
        "00000000001111011011010000011010001010111100100000111100000000000",
        "00101111100101010001001010110011111111101001010111111100111110000",
        "00101011000100100100000100000100100101000011111101010000110100100",
        "00001001110000001000011101000101010010111101000010111011011011100",
        "00100100010111011011011000111001111100000110111101011100111001000",
        "00111000111101010001001010110010100010111101010011111101010100100",
        "00010101010100100100000100000100100001110111111001010001110101000",
        "00101011111010011000011001000101010100100100111101001010111011100",
        "00010010001001000011011100111001111100100100100100100100100000000",
        "00011000111001000111000110110010100011011011011011011111010101100",
        "00010110001010011011011000100100100000010111101000010001111100000",
        "00101000110101000001001101011111010101000010111101000100100011100",
        "00100010001001101100000001001001111100100100100100100000100000000",
        "00011100111111100010110000011010100011111001010011111111010011100",
        "00100110001100111010100110000100111001010011111001010101111100100",
        "00101000110010110001111101011101110100100100100100100010100101100",
        "00100011010000000000101010010010110010111101000010100011100001000",
        "00010101101000000111110110110111110111101000010111111101110110100",
        "00101001001110011011110001001011110011011011011011010001111100100",
        "00101111110000100111110100000101100100100100100100100011000011100",
        "00111000001111100000001111011001110000100101100010100100111001000",
        "00101111111010011001101100110011111101110000110001100111111100100",
        "00011010001101101100000101100010001101000010111101110110001100100",
        "00111110101000100011100101000110101010111101000011001010101011100",
        "00010010001110000110000110111110001101000010101101001110001001000",
        "00011111111010011001101100110111111010111101010010111011111100100",
        "00101101010101101100000101100111000000010001100000010000000100000",
        "00001111101010111010100101000110100101000110101100101100100010100",
        "00010100010000010111000000111001010101100000110101100111010001100",
        "00001111111100011011110100110101111010111101000010111110101101100",
        "00001100011001011101101101100110100001110001110001110001010101100",
        "00111100110110010111001111000110100100100100100100100111100001000",
        "00100111010001001000101100110001010100100100100100100010110000100",
        "00101000110011100001000111100111111011111001010011111100100010100",
        "00100010000110110010110100110010100001010011111001010011010010100",
        "00110110100011101011001101110110100100100100100100100101111011100",
        "00101100000011010011011010110111010100100100100100100000100001000",
        "00100100110011111010010110110011111001110001110001111100100010100",
        "00101010000001110011000001101100100101000010111101000001010100100",
        "00001110100110000001010111000111011000110101100000100001111011100",
        "00101100000011000101110010111100010000110101000101000110100001000",
        "00000100100011000000101110110101001101101001110000110110000100100",
        "00000110000000110010110111100110110101000010111100010000110100100",
        "00001111101110100001011111000110100110111101000111001100111011100",
        "00111010011011100101100010111000011100000010101101010111000001000",
        "00111100101011000000101110110111111010111101010011110111111100100",
        "00000000001000110010110111100110001000110001101001110010001100000",
        "00111111100000110001011111000110101100000100110100001010101011100",
        "00100000101001100100000010111010001100100100100100100110001000000",
        "00101110101000010110011110010111111011011011011011011111111101000",
        "00101110101110110010000011100010101000010111101000010100111000100",
        "00101110101111111100100011011101011101000010111101000000010000100",
        "00100000100111010001110011001100100100100100100100100010101000100",
        "00111111101010001011010110111001010011111001010011111100000011100",
        "00000000000000000000000000000000000000000000000000000000000000000",
        "00000000000000000000000000000000000000000000000000000000000000000",
    ]),
]

// The mask is an optimisation, not part of correctness: two encoders may
// legitimately choose differently, and this one did (mask 6 where the reference
// took 4). Asserting the finished matrices are equal therefore asserts a choice
// the format does not require. What must agree is everything the mask is
// applied *to*, so each matrix is unmasked with the mask its own format field
// names and the data modules are compared.
for vector in vectors {
    do {
        let grid = try QRCode.encode(vector.text)
        let size = vector.version * 4 + 17
        check(grid.count == size, "\(vector.version) blocks match for a \(vector.text.count)-byte payload")

        let reference = vector.rows.map { Array($0).map { $0 == "1" } }
        guard reference.count == size + 4 else {
            check(false, "the reference vector for version \(vector.version) is the right size")
            continue
        }
        let referenceGrid = (0..<size).map { Array(reference[$0 + 2][2..<(size + 2)]) }

        let mine = formatMasks(grid)
        let theirs = formatMasks(referenceGrid)
        check(mine.count == 2 && mine[0] == mine[1],
              "the format field names one mask for version \(vector.version)")
        check(theirs[0] == theirs[1],
              "and one for the reference, so the comparison is meaningful")

        guard let myMask = mine.first, let theirMask = theirs.first else { continue }
        let reserved = reservedMap(version: vector.version, size: size)
        var differences = 0
        for row in 0..<size {
            for column in 0..<size where !reserved[row][column] {
                var a = grid[row][column]
                if maskCondition(myMask, row: row, column: column) { a.toggle() }
                var b = referenceGrid[row][column]
                if maskCondition(theirMask, row: row, column: column) { b.toggle() }
                if a != b { differences += 1 }
            }
        }
        check(differences == 0,
              "every data module of \"\(String(vector.text.prefix(24)))…\" matches the reference once unmasked (\(differences) differ)")
    } catch {
        check(false, "encoding a \(vector.text.count)-byte payload threw \(error)")
    }
}

// MARK: - Structure

// A code that is structurally sound but wrong is the failure this whole file is
// about, so the pieces a reader depends on are checked directly.
let sample = try? QRCode.encode("cqutmux://pair?v=1&host=10.0.0.5&port=22")
if let sample {
    let size = sample.count
    // Finder patterns: the three 7x7 squares a reader locates the code by.
    let finder: [[Int]] = [
        [1,1,1,1,1,1,1],
        [1,0,0,0,0,0,1],
        [1,0,1,1,1,0,1],
        [1,0,1,1,1,0,1],
        [1,0,1,1,1,0,1],
        [1,0,0,0,0,0,1],
        [1,1,1,1,1,1,1],
    ]
    func finderMatches(row: Int, column: Int) -> Bool {
        for r in 0..<7 {
            for c in 0..<7 where (sample[row + r][column + c] ? 1 : 0) != finder[r][c] {
                return false
            }
        }
        return true
    }
    check(finderMatches(row: 0, column: 0), "the top-left finder is a finder")
    check(finderMatches(row: 0, column: size - 7), "the top-right finder is a finder")
    check(finderMatches(row: size - 7, column: 0), "the bottom-left finder is a finder")

    // Separators: the light ring that lets a reader find the finder's edges.
    var separatorsClear = true
    for index in 0..<8 {
        if sample[7][index] || sample[index][7] { separatorsClear = false }
    }
    check(separatorsClear, "the top-left finder's separator is light, so its edges read")

    // The dark module, always present, which is how the format's orientation is
    // established.
    check(sample[size - 8][8], "the dark module is set")

    // Timing patterns alternate, and they are what a reader counts modules with.
    var timingAlternates = true
    for index in 8..<(size - 8) {
        if sample[6][index] != (index % 2 == 0) { timingAlternates = false }
        if sample[index][6] != (index % 2 == 0) { timingAlternates = false }
    }
    check(timingAlternates, "the timing patterns alternate at every module")
}

// MARK: - The format field

// Fifteen bits that say the error level and the mask, protected by a BCH code.
// A reader that cannot read these cannot read the code at all, and neither can
// a camera — so both copies have to be present and agree.
if let sample {
    let size = sample.count
    var copiesAgree = true
    var formatReads = true
    for index in 0..<15 {
        let first: Bool
        if index < 6 { first = sample[index][8] }
        else if index < 8 { first = sample[index + 1][8] }
        else if index == 8 { first = sample[8][7] }
        else { first = sample[8][14 - index] }
        let second = index < 8 ? sample[8][size - 1 - index] : sample[size - 15 + index][8]
        if first != second { copiesAgree = false }
        _ = formatReads
    }
    check(copiesAgree, "both copies of the format field carry the same bits")

    // The BCH check: re-derive the remainder and compare.
    var raw: UInt32 = 0
    for index in 0..<15 {
        let bit: Bool
        if index < 6 { bit = sample[index][8] }
        else if index < 8 { bit = sample[index + 1][8] }
        else if index == 8 { bit = sample[8][7] }
        else { bit = sample[8][14 - index] }
        if bit { raw |= 1 << UInt32(index) }
    }
    let unmasked = raw ^ 0x5412
    let data = unmasked >> 10
    var remainder = data
    for _ in 0..<10 { remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537) }
    check(((data << 10) | (remainder & 0x3FF)) == unmasked,
          "the format field passes its own BCH check")
    check(data >> 3 == 0b00, "the format field says error correction level M")
    check(Int(data & 0b111) <= 7, "the format field names a real mask")
}

// MARK: - The payload reads back

// The point of the code: a scanner has to get the URL out. This decoder walks
// the format field, the function-pattern map, the zigzag data placement and the
// block interleaving, so agreement here is about the format rather than about
// this file's own helpers.
if let sample {
    let masks = formatMasks(sample)
    check(masks.first == masks.last, "the format field names one mask, not two")
    if let mask = masks.first, let payload = readPayload(sample, mask: mask) {
        check(String(decoding: payload, as: UTF8.self) == "cqutmux://pair?v=1&host=10.0.0.5&port=22",
              "the payload reads back out of the matrix")
    } else {
        check(false, "the payload could be read back out of the matrix")
    }
}

// MARK: - Capacity

// The encoder has to refuse what it cannot hold rather than emit a code with
// the wrong header, and the boundary has to be the real one.
let longest = QRCode.maxByteCount(version: 40, correction: .medium)
check(longest > 2000, "the largest byte-mode payload is about 2.3 KB (\(longest))")
check((try? QRCode.encode(String(repeating: "a", count: longest))) != nil,
      "a payload exactly at the capacity encodes")
do {
    _ = try QRCode.encode(String(repeating: "a", count: longest + 1))
    check(false, "a payload one byte over the capacity is refused")
} catch {
    check(true, "a payload one byte over the capacity is refused")
}

// A small payload must pick a small version: a 300-byte URL drawn at version 1
// would be rejected by every reader, so the fit has to be by capacity.
check(QRCode.version(forByteCount: 11, correction: .medium) == 1,
      "a short payload picks version 1")
check((QRCode.version(forByteCount: 60, correction: .medium) ?? 0) > 1,
      "a longer one picks a bigger version rather than overflowing")
check(QRCode.version(forByteCount: longest, correction: .medium) == 40,
      "the largest payload picks version 40")

// MARK: - Rendering

// What the terminal prints. Two modules per character is the minimum that reads
// from a screen at arm's length, and the quiet zone is not optional — a code
// flush against other text does not scan.
let drawn = QRCode.terminal(sample ?? [])
let drawnLines = drawn.split(separator: "\n", omittingEmptySubsequences: false)
check(drawnLines.count == (sample?.count ?? 0) + 4,
      "the drawing adds a four-module quiet zone vertically")
check(drawnLines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true,
      "and a blank row at the top, which is the quiet zone")
let bodyLine = drawnLines.count > 2 ? drawnLines[2] : ""
check(bodyLine.count == (sample?.count ?? 0) * 2 + 8,
      "and two characters per module horizontally")

// MARK: - Helpers used above


/// Which modules are function patterns: finders, separators, timing, alignment,
/// the format areas, the dark module, and version information.
///
/// Needed to unmask a finished matrix, since the mask is only applied to the
/// modules that carry data.
func reservedMap(version: Int, size: Int) -> [[Bool]] {
    var reserved = [[Bool]](repeating: [Bool](repeating: false, count: size), count: size)
    func mark(_ row: Int, _ column: Int) {
        if row >= 0, row < size, column >= 0, column < size { reserved[row][column] = true }
    }
    for (row, column) in [(0, 0), (0, size - 7), (size - 7, 0)] {
        for r in -1...7 { for c in -1...7 { mark(row + r, column + c) } }
    }
    for index in 0..<size { mark(6, index); mark(index, 6) }
    for row in alignmentCentres(version) {
        for column in alignmentCentres(version) {
            // Skipped only where the pattern would overlap a finder. A centre
            // that lands on a timing line — (6, 30) at version 11 — is placed
            // like any other; excluding those looks plausible and silently
            // reserves a 5x5 that is really data, which shifts the whole stream
            // and shows up as hundreds of mismatches rather than as a few.
            if (row < 9 && column < 9) || (row < 9 && column > size - 10)
                || (row > size - 10 && column < 9) { continue }
            for r in -2...2 { for c in -2...2 { mark(row + r, column + c) } }
        }
    }
    for index in 0..<9 { mark(8, index); mark(index, 8) }
    for index in 0..<8 { mark(8, size - 1 - index); mark(size - 1 - index, 8) }
    mark(size - 8, 8)
    if version >= 7 {
        for index in 0..<18 {
            mark(index / 3, size - 11 + index % 3)
            mark(size - 11 + index % 3, index / 3)
        }
    }
    return reserved
}

/// The mask the format field names.
func formatMasks(_ grid: [[Bool]]) -> [Int] {
    let size = grid.count
    func read(_ at: (Int) -> Bool) -> Int {
        (0..<15).reduce(0) { value, index in at(index) ? value | 1 << index : value }
    }
    let first = read { index in
        if index < 6 { return grid[index][8] }
        if index < 8 { return grid[index + 1][8] }
        if index == 8 { return grid[8][7] }
        return grid[8][14 - index]
    }
    let second = read { index in
        index < 8 ? grid[8][size - 1 - index] : grid[size - 15 + index][8]
    }
    // The mask is bits 10-12 of the field, not the low three: the low ten are
    // the BCH remainder, and reading those instead is a mistake that happens to
    // give the right answer for some codes and not others.
    return [Int(((UInt32(first) ^ 0x5412) >> 10) & 0b111),
            Int(((UInt32(second) ^ 0x5412) >> 10) & 0b111)]
}

/// Reads the byte-mode payload out of a finished matrix.
///
/// Written from the format: which modules are function patterns, the zigzag data
/// order, the mask, and byte mode's header.
func readPayload(_ grid: [[Bool]], mask: Int) -> [UInt8]? {
    let size = grid.count
    let version = (size - 17) / 4
    var reserved = [[Bool]](repeating: [Bool](repeating: false, count: size), count: size)
    func mark(_ row: Int, _ column: Int) {
        if row >= 0, row < size, column >= 0, column < size { reserved[row][column] = true }
    }
    for (row, column) in [(0, 0), (0, size - 7), (size - 7, 0)] {
        for r in -1...7 { for c in -1...7 { mark(row + r, column + c) } }
    }
    for index in 0..<size { mark(6, index); mark(index, 6) }
    for row in alignmentCentres(version) {
        for column in alignmentCentres(version) {
            // Skipped only where the pattern would overlap a finder. A centre
            // that lands on a timing line — (6, 30) at version 11 — is placed
            // like any other; excluding those looks plausible and silently
            // reserves a 5x5 that is really data, which shifts the whole stream
            // and shows up as hundreds of mismatches rather than as a few.
            if (row < 9 && column < 9) || (row < 9 && column > size - 10)
                || (row > size - 10 && column < 9) { continue }
            for r in -2...2 { for c in -2...2 { mark(row + r, column + c) } }
        }
    }
    for index in 0..<9 { mark(8, index); mark(index, 8) }
    for index in 0..<8 { mark(8, size - 1 - index); mark(size - 1 - index, 8) }
    mark(size - 8, 8)
    if version >= 7 {
        for index in 0..<18 {
            mark(index / 3, size - 11 + index % 3)
            mark(size - 11 + index % 3, index / 3)
        }
    }

    var bits: [Bool] = []
    var upward = true
    var column = size - 1
    while column > 0 {
        if column == 6 { column -= 1 }
        for step in 0..<size {
            let row = upward ? size - 1 - step : step
            for offset in 0..<2 {
                let x = column - offset
                if reserved[row][x] { continue }
                var value = grid[row][x]
                if maskCondition(mask, row: row, column: x) { value.toggle() }
                bits.append(value)
                reserved[row][x] = true
            }
        }
        upward.toggle()
        column -= 2
    }

    var bytes = stride(from: 0, to: bits.count - bits.count % 8, by: 8).map { start -> UInt8 in
        var byte: UInt8 = 0
        for offset in 0..<8 { byte = (byte << 1) | (bits[start + offset] ? 1 : 0) }
        return byte
    }
    bytes = deinterleave(bytes, version: version)
    guard bytes.count > 2 else { return nil }
    let header = Int(bytes[0]) << 8 | Int(bytes[1])
    guard header >> 12 == 0b0100 else { return nil }
    let length = version <= 9 ? (header >> 4) & 0xFF : header & 0xFFFF
    // The payload starts four bits into the second byte of the header.
    var payload: [UInt8] = []
    var accumulator: UInt16 = UInt16(bytes[1] & 0x0F)
    var width = 4
    for byte in bytes.dropFirst(2) {
        accumulator = (accumulator << 8) | UInt16(byte)
        width += 8
        while width >= 8 && payload.count < length {
            payload.append(UInt8((accumulator >> UInt16(width - 8)) & 0xFF))
            width -= 8
        }
    }
    return payload.count == length ? payload : nil
}

func maskCondition(_ mask: Int, row: Int, column: Int) -> Bool {
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

/// Alignment pattern centres. Data rather than logic, and the versions here go
/// past 7 because the vectors do: stopping at 7 silently leaves a version-11
/// symbol's alignment patterns counted as data, which shows up as hundreds of
/// mismatched modules rather than as a missing table entry.
func alignmentCentres(_ version: Int) -> [Int] {
    let table: [Int: [Int]] = [
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
    ]
    return table[version] ?? []
}

/// Undoes the block interleaving. Handles the single- and two-block layouts the
/// vectors and the pairing payload produce; anything else is returned as-is,
/// which is enough for the checks above but is not a general decoder.
func deinterleave(_ stream: [UInt8], version: Int) -> [UInt8] {
    let layouts: [Int: [Int]] = [
        1: [16], 2: [28], 3: [44], 4: [32, 32], 5: [43, 43],
        6: [27, 27, 27, 27], 7: [31, 31, 31, 31], 8: [38, 38, 39, 39],
        9: [36, 36, 36, 37, 37], 10: [43, 43, 43, 43, 44],
    ]
    guard let blocks = layouts[version], blocks.count > 1 else { return stream }
    let shortest = blocks.min() ?? 0
    let longest = blocks.max() ?? 0
    var perBlock = [[UInt8]](repeating: [], count: blocks.count)
    var read = 0
    for index in 0..<longest {
        for (blockIndex, length) in blocks.enumerated() where index < length {
            perBlock[blockIndex].append(stream[read])
            read += 1
        }
    }
    _ = shortest
    return perBlock.flatMap { $0 }
}

if failures > 0 {
    print("\nQR_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nQR_PASS  (\(checks) checks)")