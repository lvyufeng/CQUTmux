import Foundation
import Crypto

/// `bcrypt_pbkdf`, the key derivation OpenSSH uses for passphrase-protected
/// keys — and nothing else in the app.
///
/// Why this exists
/// ---------------
/// An `ssh-keygen`-encrypted key is not PBKDF2-with-HMAC in any of its usual
/// forms. OpenSSH derives the AES key with a variant of bcrypt: the password
/// and salt are each hashed with SHA-512, those digests are fed to Blowfish,
/// and 64 rounds of key-schedule expansion are run against a fixed magic
/// string. The output is then written back non-linearly, so no byte of it can
/// be computed without computing all of it.
///
/// The consequence for anyone reading this: there is no shortcut and no
/// "close enough". A single wrong constant or one wrapping-add written as a
/// trapping-add produces a 32-byte key that is simply the wrong key, and the
/// failure appears much later as `ssh` rejecting a password — a message that
/// says nothing about the derivation. The only way to know this is right is to
/// derive a key for a real `ssh-keygen` file and compare.
///
/// That is what `KeyImportChecks` does: the fixture is a key made here, with a
/// passphrase, and the check compares the public key derived from the decrypted
/// seed against the `.pub` ssh-keygen wrote beside it. A derivation that was
/// wrong would produce 32 bytes that are not the seed, and the two public keys
/// would differ.
public enum BcryptPBKDF {
    public enum Error: Swift.Error, CustomStringConvertible {
        case invalidRoundCount
        case invalidOutputLength(Int)

        public var description: String {
            switch self {
            case .invalidRoundCount: "bcrypt_pbkdf needs at least one round"
            case .invalidOutputLength(let n): "bcrypt_pbkdf cannot produce \(n) bytes"
            }
        }
    }

    /// The 32-byte bcrypt hash of a password/salt pair, which is the unit of
    /// work `derive` iterates.
    ///
    /// Named after the reference's `bcrypt_hash` rather than something more
    /// descriptive because the name is the only clue that this is deliberately
    /// *not* the bcrypt that hashes passwords: there is no version string, no
    /// cost encoding and no base64, and the magic text below is longer than
    /// bcrypt's own.
    static func hash(password: [UInt8], salt: [UInt8]) -> [UInt8] {
        // The magic string is 32 bytes — exactly one output block — and is
        // encrypted as though it were the plaintext. Using bcrypt's own
        // "OrpheanBeholderScryDoubt" here yields a different, wrong key.
        let ciphertext = Array("OxychromaticBlowfishSwatDynamite".utf8)

        var state = Blowfish.initState()
        // `expandstate` takes the salt as the data and the password as the key;
        // swapping them is a silent wrong answer, not a crash.
        Blowfish.expandState(&state, salt: salt, key: password)
        // 64 rounds of "salt, then password" expansion. The reference's comment
        // calls this the reason the hash is expensive; the count is fixed by
        // the format, not a tunable.
        for _ in 0..<64 {
            Blowfish.expand0state(&state, salt)
            Blowfish.expand0state(&state, password)
        }

        // Encrypt the magic string, then 64 more times — the block is its own
        // input each round, so this is ECB in a loop.
        var words = [UInt32](repeating: 0, count: 8)
        var cursor = 0
        for i in 0..<8 {
            words[i] = Blowfish.stream2word(ciphertext, &cursor)
        }
        for _ in 0..<64 {
            for i in stride(from: 0, to: 8, by: 2) {
                (words[i], words[i + 1]) = Blowfish.encipher(&state, words[i], words[i + 1])
            }
        }

        // Little-endian on the way out. The rest of the format is big-endian,
        // so this is the one place the byte order flips, and it is easy to
        // "fix" into being wrong.
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<8 {
            out[4 * i + 0] = UInt8(words[i] & 0xff)
            out[4 * i + 1] = UInt8((words[i] >> 8) & 0xff)
            out[4 * i + 2] = UInt8((words[i] >> 16) & 0xff)
            out[4 * i + 3] = UInt8((words[i] >> 24) & 0xff)
        }
        return out
    }

    /// Derives `length` bytes from `password` and `salt` in `rounds` rounds.
    ///
    /// The loop is PBKDF2's, with two deviations from RFC 2898 that the format
    /// depends on:
    ///
    /// 1. The digest is bcrypt, not HMAC. Each round hashes the *previous
    ///    round's output* with SHA-512 to get the next salt, so the chain is
    ///    `salt → sha512 → hash → sha512 → hash → …`, not `HMAC(pass, salt)`.
    /// 2. The output bytes are scattered across the result instead of written
    ///    consecutively. When more than one block is needed the reference
    ///    interleaves them, so a caller cannot compute half the key and stop;
    ///    with the 32-byte blocks this format uses, a single block is the
    ///    common case and the scatter is invisible.
    public static func derive(
        password: [UInt8],
        salt: [UInt8],
        rounds: Int,
        length: Int
    ) throws -> [UInt8] {
        guard rounds >= 1 else { throw Error.invalidRoundCount }
        guard length > 0, length <= 32 * 32 else { throw Error.invalidOutputLength(length) }

        // `stride`/`amt` are how the scatter is spread. For the 32-byte block
        // this format uses they are both 1, so the general form is kept for
        // correctness against the reference rather than because any OpenSSH key
        // exercises it.
        let stride = (length + 31) / 32
        var amt = (length + stride - 1) / stride

        let sha2pass = Array(SHA512.hash(data: Data(password)))
        var key = [UInt8](repeating: 0, count: length)
        let originalLength = length
        var remaining = length
        var count = 1

        while remaining > 0 {
            // The block index goes in big-endian, appended to the salt.
            var countSalt = [UInt8](repeating: 0, count: 4)
            countSalt[0] = UInt8((UInt32(count) >> 24) & 0xff)
            countSalt[1] = UInt8((UInt32(count) >> 16) & 0xff)
            countSalt[2] = UInt8((UInt32(count) >> 8) & 0xff)
            countSalt[3] = UInt8(UInt32(count) & 0xff)

            var sha2salt = Array(SHA512.hash(data: Data(salt + countSalt)))
            // `round` is this round's raw hash output; `out` is the running XOR
            // of every round. The next salt is derived from `round`, *not* from
            // `out` — hashing the accumulator instead is a natural-looking
            // mistake that produces a plausible key and matches nothing, and it
            // is why the vector below is checked rather than reasoned about.
            var round = hash(password: sha2pass, salt: sha2salt)
            var out = round

            for _ in 1..<rounds {
                sha2salt = Array(SHA512.hash(data: Data(round)))
                round = hash(password: sha2pass, salt: sha2salt)
                for j in 0..<32 { out[j] ^= round[j] }
            }

            amt = min(amt, remaining)
            var written = 0
            for i in 0..<amt {
                let dest = i * stride + (count - 1)
                if dest >= originalLength { break }
                key[dest] = out[i]
                written += 1
            }
            remaining -= written
            count += 1
        }

        return key
    }

    /// The same derivation with the passphrase as text.
    ///
    /// The passphrase is UTF-8, which is what `ssh` uses; a passphrase typed on
    /// the phone and the same characters typed in a terminal have to produce
    /// the same bytes, and any pre-normalisation would break that for the
    /// non-ASCII cases rather than fix them.
    public static func derive(passphrase: String, salt: [UInt8], rounds: Int, length: Int) throws -> [UInt8] {
        try derive(password: Array(passphrase.utf8), salt: salt, rounds: rounds, length: length)
    }
}