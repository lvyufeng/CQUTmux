import Foundation

/// AES-128/192/256 in counter mode, which is what `aes{128,192,256}-ctr`
/// private keys are encrypted with.
///
/// Why not a system cipher
/// -----------------------
/// `.build/checkouts/swift-crypto` ships BoringSSL's Blowfish but no AES
/// counter mode with the byte order OpenSSH uses, and reaching for CommonCrypto
/// would make this package Apple-only for one function that is twenty lines of
/// loop and one block cipher. The block cipher is written here instead, and the
/// check decrypts a real `ssh-keygen` key with it — which is a stronger
/// statement than "it compiles".
///
/// Only the forward direction exists. CTR is a stream: the same keystream is
/// XORed to encrypt and to decrypt, so a separate inverse cipher would be dead
/// code, and dead crypto code is code that has never been run.
///
/// The S-box is computed rather than written down. A 256-entry table typed out
/// by hand is a table with one wrong entry somewhere, and the resulting bug
/// appears only for keys whose bytes hit it. Deriving it from the field
/// definition costs a millisecond once and cannot be mistyped.
enum AES {
    /// The cipher's block size, in bytes. Also the counter width.
    static let blockSize = 16

    /// One AES block, encrypted.
    struct Block {
        private let roundKeys: [UInt32]
        private let rounds: Int

        /// Expands a 16-, 24- or 32-byte key.
        init?(key: [UInt8]) {
            let nk: Int
            switch key.count {
            case 16: nk = 4
            case 24: nk = 6
            case 32: nk = 8
            default: return nil
            }
            self.rounds = nk + 6
            var words = [UInt32]()
            words.reserveCapacity(4 * (rounds + 1))
            for i in 0..<nk {
                words.append(
                    UInt32(key[4 * i]) << 24
                        | UInt32(key[4 * i + 1]) << 16
                        | UInt32(key[4 * i + 2]) << 8
                        | UInt32(key[4 * i + 3])
                )
            }
            let total = 4 * (rounds + 1)
            var rcon: UInt8 = 1
            for i in nk..<total {
                var temp = words[i - 1]
                if i % nk == 0 {
                    // Rotate, substitute, then XOR the round constant — in that
                    // order. The rotate is by one byte, not one bit.
                    temp = AES.subWord(AES.rotWord(temp)) ^ (UInt32(rcon) << 24)
                    // The constant doubles in GF(2^8) with 0x1b reduction.
                    rcon = AES.multiply(rcon, 2)
                } else if nk > 6 && i % nk == 4 {
                    temp = AES.subWord(temp)
                }
                words.append(words[i - nk] ^ temp)
            }
            self.roundKeys = words
        }

        /// Encrypts one 16-byte block.
        func encrypt(_ input: [UInt8]) -> [UInt8] {
            var state = input
            addRoundKey(&state, 0)
            for round in 1..<rounds {
                subBytes(&state)
                shiftRows(&state)
                mixColumns(&state)
                addRoundKey(&state, round)
            }
            // The last round has no MixColumns; adding it here is the classic
            // "it decrypts but only for zero bytes" mistake.
            subBytes(&state)
            shiftRows(&state)
            addRoundKey(&state, rounds)
            return state
        }

        private func addRoundKey(_ state: inout [UInt8], _ round: Int) {
            for c in 0..<4 {
                let word = roundKeys[round * 4 + c]
                state[4 * c + 0] ^= UInt8((word >> 24) & 0xff)
                state[4 * c + 1] ^= UInt8((word >> 16) & 0xff)
                state[4 * c + 2] ^= UInt8((word >> 8) & 0xff)
                state[4 * c + 3] ^= UInt8(word & 0xff)
            }
        }

        private func subBytes(_ state: inout [UInt8]) {
            for i in 0..<16 { state[i] = AES.sBox[Int(state[i])] }
        }

        private func shiftRows(_ state: inout [UInt8]) {
            // Column-major: byte i sits at row i%4, column i/4. Row r rotates
            // left by r, which is a rotation of the *indices across columns*.
            var out = state
            for r in 1..<4 {
                for c in 0..<4 {
                    out[4 * c + r] = state[4 * ((c + r) % 4) + r]
                }
            }
            state = out
        }

        private func mixColumns(_ state: inout [UInt8]) {
            for c in 0..<4 {
                let a0 = state[4 * c], a1 = state[4 * c + 1]
                let a2 = state[4 * c + 2], a3 = state[4 * c + 3]
                state[4 * c + 0] = AES.multiply(a0, 2) ^ AES.multiply(a1, 3) ^ a2 ^ a3
                state[4 * c + 1] = a0 ^ AES.multiply(a1, 2) ^ AES.multiply(a2, 3) ^ a3
                state[4 * c + 2] = a0 ^ a1 ^ AES.multiply(a2, 2) ^ AES.multiply(a3, 3)
                state[4 * c + 3] = AES.multiply(a0, 3) ^ a1 ^ a2 ^ AES.multiply(a3, 2)
            }
        }
    }

    /// XORs `data` with the keystream produced by encrypting `iv, iv+1, …`.
    ///
    /// The counter is the whole 128-bit block, incremented big-endian with the
    /// carry running from the last byte to the first. OpenSSH does not wrap it
    /// differently, and a key long enough to overflow the counter does not
    /// exist — but the carry has to be there for the low byte crossing 0xff,
    /// which happens every 256 blocks.
    static func ctr(_ data: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        guard iv.count == blockSize, let block = Block(key: key) else { return nil }
        var counter = iv
        var out = [UInt8](repeating: 0, count: data.count)
        var offset = 0
        while offset < data.count {
            let keystream = block.encrypt(counter)
            let chunk = min(blockSize, data.count - offset)
            for i in 0..<chunk {
                out[offset + i] = data[offset + i] ^ keystream[i]
            }
            offset += chunk
            // Big-endian increment of the full 128-bit block.
            var i = blockSize - 1
            while i >= 0 {
                counter[i] = counter[i] &+ 1
                if counter[i] != 0 { break }
                i -= 1
            }
        }
        return out
    }

    // MARK: - The field and the box

    /// Multiplication in GF(2^8) modulo x^8 + x^4 + x^3 + x + 1 (0x11b).
    static func multiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var x = a, y = b
        var result: UInt8 = 0
        while y != 0 {
            if y & 1 != 0 { result ^= x }
            let high = x & 0x80
            x <<= 1
            // The reduction is conditional on the bit shifted out, not on the
            // result's high bit after the shift.
            if high != 0 { x ^= 0x1b }
            y >>= 1
        }
        return result
    }

    /// The multiplicative inverse, by exponentiation: a^254 = a^-1 in a field
    /// of order 256. Extended Euclid would be faster and much easier to get
    /// subtly wrong.
    private static func inverse(_ a: UInt8) -> UInt8 {
        if a == 0 { return 0 }
        var result: UInt8 = 1
        var base = a
        var exponent = 254
        while exponent > 0 {
            if exponent & 1 != 0 { result = multiply(result, base) }
            base = multiply(base, base)
            exponent >>= 1
        }
        return result
    }

    private static func rotateLeft(_ value: UInt8, _ by: UInt32) -> UInt8 {
        (value << by) | (value >> (8 - by))
    }

    /// The AES substitution box: the field inverse, then the affine transform
    /// `b ^ rotl(b,1) ^ rotl(b,2) ^ rotl(b,3) ^ rotl(b,4) ^ 0x63`.
    static let sBox: [UInt8] = (0..<256).map { i in
        let b = inverse(UInt8(i))
        return b
            ^ rotateLeft(b, 1) ^ rotateLeft(b, 2) ^ rotateLeft(b, 3) ^ rotateLeft(b, 4)
            ^ 0x63
    }

    private static func subWord(_ word: UInt32) -> UInt32 {
        UInt32(sBox[Int((word >> 24) & 0xff)]) << 24
            | UInt32(sBox[Int((word >> 16) & 0xff)]) << 16
            | UInt32(sBox[Int((word >> 8) & 0xff)]) << 8
            | UInt32(sBox[Int(word & 0xff)])
    }

    private static func rotWord(_ word: UInt32) -> UInt32 {
        (word << 8) | (word >> 24)
    }
}