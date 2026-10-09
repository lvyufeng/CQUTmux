import Foundation
import Crypto

/// Ed25519 key helpers in OpenSSH's wire and file formats.
///
/// Only the seed (32 raw bytes) is ever persisted by the app — the OpenSSH
/// blob never leaves the Keychain, and the public half is derived on demand.
public enum Ed25519OpenSSH {
    public enum KeyError: Error, CustomStringConvertible {
        case malformed(String)
        case unsupported(String)

        public var description: String {
            switch self {
            case .malformed(let why): "malformed OpenSSH key: \(why)"
            case .unsupported(let why): "unsupported OpenSSH key: \(why)"
            }
        }
    }

    /// Generates a fresh keypair. The returned seed is what gets stored.
    public static func generate() throws -> (seed: Data, publicKey: String) {
        let key = Curve25519.Signing.PrivateKey()
        let seed = key.rawRepresentation
        return (seed, try publicKey(fromSeed: seed))
    }

    /// The `ssh-ed25519 AAAA… comment` line to paste into `authorized_keys`.
    public static func publicKey(fromSeed seed: Data, comment: String = "cqutmux") throws -> String {
        let key: Curve25519.Signing.PrivateKey
        do {
            key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        } catch {
            throw KeyError.malformed("seed must be \(32) bytes of ed25519 key material")
        }
        var blob = Data()
        blob.append(sshString(Data("ssh-ed25519".utf8)))
        blob.append(sshString(key.publicKey.rawRepresentation))
        return "ssh-ed25519 \(blob.base64EncodedString()) \(comment)"
    }

    /// Extracts the 32-byte seed from an unencrypted `openssh-key-v1` PEM.
    public static func seed(fromOpenSSHPrivateKey pem: String) throws -> Data {
        try seed(fromOpenSSHPrivateKey: pem, passphrase: nil)
    }

    /// Extracts the 32-byte seed from an `openssh-key-v1` PEM.
    ///
    /// `passphrase` is what the key was written with, or nil for an unencrypted
    /// one. Supplying a passphrase for a key that was not encrypted is not an
    /// error: the `none` cipher has no key to derive, so the passphrase is
    /// simply unused, and the alternative — refusing — would make the caller
    /// decide which keys need one, which it cannot see.
    ///
    /// The decryption is where the two halves of the format meet: the AES key
    /// and IV both come out of `bcrypt_pbkdf`, and both are derived from the
    /// passphrase and the salt stored in the header. Getting the derivation
    /// right and the IV wrong produces a plausible-looking failure — the check
    /// integers inside the decrypted blob will not match — so a wrong
    /// passphrase and a broken derivation are deliberately reported the same
    /// way, because from here they are the same thing.
    public static func seed(fromOpenSSHPrivateKey pem: String, passphrase: String?) throws -> Data {
        let body = pem
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let blob = Data(base64Encoded: body) else {
            throw KeyError.malformed("not valid base64")
        }

        let magic = Data("openssh-key-v1\u{0}".utf8)
        guard blob.starts(with: magic) else {
            throw KeyError.malformed("missing openssh-key-v1 header")
        }
        var reader = Reader(blob.dropFirst(magic.count))

        let cipher = try reader.string()
        let kdf = try reader.string()
        let kdfOptions = try reader.string()

        _ = try reader.uint32() // number of keys
        _ = try reader.string() // public key blob (redundant with the private half)

        var privateBlob = try reader.string()
        if cipher != Data("none".utf8) || kdf != Data("none".utf8) {
            guard let passphrase else {
                throw KeyError.unsupported("this key is encrypted; a passphrase is needed")
            }
            privateBlob = try decrypt(
                privateBlob,
                cipher: String(decoding: cipher, as: UTF8.self),
                kdf: String(decoding: kdf, as: UTF8.self),
                kdfOptions: kdfOptions,
                passphrase: passphrase
            )
        }

        var pr = Reader(privateBlob)
        let check1 = try pr.uint32()
        let check2 = try pr.uint32()
        guard check1 == check2 else {
            // For an encrypted key this is what a wrong passphrase looks like:
            // the decrypted bytes are noise, so the two equal check integers
            // are not equal. Saying so is the difference between the user
            // retyping the passphrase and the user concluding the file is
            // corrupt.
            if cipher != Data("none".utf8) {
                throw KeyError.malformed("the passphrase did not decrypt this key")
            }
            throw KeyError.malformed("check integers differ")
        }

        let keyType = try pr.string()
        guard keyType == Data("ssh-ed25519".utf8) else {
            throw KeyError.unsupported("only ed25519 keys are supported, got \(String(decoding: keyType, as: UTF8.self))")
        }
        _ = try pr.string() // public key, 32 bytes
        let privateKey = try pr.string()
        guard privateKey.count >= 32 else { throw KeyError.malformed("private key too short") }
        return privateKey.prefix(32)
    }

    /// Writes a seed back out as an unencrypted `openssh-key-v1` PEM.
    ///
    /// The exact inverse of `seed(fromOpenSSHPrivateKey:)`, and deliberately
    /// unencrypted: the app holds a bare 32-byte seed and has no passphrase to
    /// encrypt with. That makes this a *portability* export — it lets a key
    /// leave for a machine that cannot scan a QR code — and the caller is
    /// expected to gate it behind a biometric prompt, because what it produces
    /// is a private key in a text field.
    ///
    /// The check integers must match each other or `ssh-keygen` rejects the
    /// file as corrupt; the padding is the block size the format requires.
    public static func openSSHPrivateKey(fromSeed seed: Data, comment: String = "cqutmux") throws -> String {
        try openSSHPrivateKey(fromSeed: seed, comment: comment, passphrase: nil)
    }

    /// Writes a seed out as an `openssh-key-v1` PEM, encrypted when a
    /// passphrase is given.
    ///
    /// The encryption is the same construction OpenSSH uses and the same one
    /// `decrypt` above reads back, which is the point: it makes the reader
    /// exercise both directions. A round trip through this function proves the
    /// derivation, the cipher and the format against each other, but *not*
    /// against OpenSSH — only a file `ssh-keygen` wrote can do that, and
    /// `KeyImportChecks` uses one.
    ///
    /// The salt is passed in rather than generated here so the output is
    /// deterministic and the check can diff it. The app never calls this with a
    /// passphrase: it stores the seed and the passphrase separately, so that
    /// changing a host's passphrase does not mean rewriting its key.
    public static func openSSHPrivateKey(
        fromSeed seed: Data,
        comment: String = "cqutmux",
        passphrase: String?,
        salt: Data? = nil,
        rounds: Int = 16
    ) throws -> String {
        var privateBlob = Data()
        // Two equal check integers. Derived from the seed rather than random
        // so the output is deterministic, which is what makes it diffable in
        // the check script.
        let check = UInt32(bigEndian: seed.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        privateBlob.append(uint32(check))
        privateBlob.append(uint32(check))
        privateBlob.append(sshString(Data("ssh-ed25519".utf8)))
        let publicBytes = try publicKeyBytes(fromSeed: seed)
        privateBlob.append(sshString(publicBytes))
        privateBlob.append(sshString(seed + publicBytes))
        privateBlob.append(sshString(Data(comment.utf8)))
        // Pad to the cipher block size with 1, 2, 3, … The format requires it
        // even for `none`, and a reader that ignores it still needs the length
        // to be a multiple of eight.
        var pad: UInt8 = 1
        while privateBlob.count % 8 != 0 {
            privateBlob.append(pad)
            pad += 1
        }

        var cipher = "none"
        var kdf = "none"
        var kdfOptions = Data()
        var storedBlob = privateBlob
        if let passphrase {
            // The block is eight for `none` and the cipher's block size (16 to
            // AES) for everything else, so an encrypted key is padded to the
            // wider boundary before it is encrypted — padding after encryption
            // would leave the reader unable to tell padding from ciphertext.
            while storedBlob.count % AES.blockSize != 0 {
                storedBlob.append(pad)
                pad += 1
            }
            // A 16-byte salt, which is what ssh-keygen writes. Generated from
            // SystemRandomNumberGenerator unless the caller supplied one.
            let saltBytes: Data
            if let salt {
                saltBytes = salt
            } else {
                var generator = SystemRandomNumberGenerator()
                saltBytes = Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) })
            }
            cipher = "aes256-ctr"
            kdf = "bcrypt"
            var options = Data()
            options.append(sshString(saltBytes))
            options.append(uint32(UInt32(rounds)))
            kdfOptions = options

            let (key, iv) = try derivedKeyAndIV(
                kdfOptions: kdfOptions,
                cipher: cipher,
                passphrase: passphrase
            )
            guard let encrypted = AES.ctr([UInt8](storedBlob), key: key, iv: iv) else {
                throw KeyError.malformed("could not encrypt the key")
            }
            storedBlob = Data(encrypted)
        }

        var blob = Data("openssh-key-v1\u{0}".utf8)
        blob.append(sshString(Data(cipher.utf8)))
        blob.append(sshString(Data(kdf.utf8)))
        blob.append(sshString(kdfOptions))
        blob.append(uint32(1))                      // one key
        // The outer field is the whole `ssh-ed25519` blob — algorithm name
        // *and* key — not the 32 raw bytes. The copy inside the private half is
        // the raw key alone, so the two are not interchangeable, and writing
        // the raw bytes here produces a file ssh-keygen rejects as "invalid
        // format" while the app's own reader happily reads it back.
        var publicBlob = Data()
        publicBlob.append(sshString(Data("ssh-ed25519".utf8)))
        publicBlob.append(sshString(publicBytes))
        blob.append(sshString(publicBlob))
        blob.append(sshString(storedBlob))

        let body = blob.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(body)\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    /// The 32-byte ed25519 public key, raw.
    public static func publicKeyBytes(fromSeed seed: Data) throws -> Data {
        do {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
        } catch {
            throw KeyError.malformed("seed must be 32 bytes of ed25519 key material")
        }
    }

    // MARK: - The encrypted container

    /// The AES key and IV for an encrypted key, derived from its own header.
    ///
    /// Both come out of one `bcrypt_pbkdf` call of `2 * keyLength` bytes: the
    /// first half is the key and the second is the IV, in that order. The IV
    /// is the block size in every cipher OpenSSH offers, and the salt and round
    /// count come from the kdf options — which is why a key carries them
    /// rather than relying on defaults.
    private static func derivedKeyAndIV(
        kdfOptions: Data,
        cipher: String,
        passphrase: String
    ) throws -> (key: [UInt8], iv: [UInt8]) {
        let keyLength: Int
        switch cipher {
        case "aes256-ctr": keyLength = 32
        case "aes192-ctr": keyLength = 24
        case "aes128-ctr": keyLength = 16
        default:
            throw KeyError.unsupported("the key uses \(cipher), which this app cannot read")
        }

        // kdf options: a string holding the salt, then the round count.
        var options = Reader(kdfOptions)
        let salt = try options.string()
        let rounds = Int(try options.uint32())
        guard !salt.isEmpty else { throw KeyError.malformed("the key's salt is empty") }

        let material = try BcryptPBKDF.derive(
            passphrase: passphrase,
            salt: [UInt8](salt),
            rounds: rounds,
            length: keyLength + 16
        )
        return (Array(material[0..<keyLength]), Array(material[keyLength..<(keyLength + 16)]))
    }

    /// Decrypts the private half of an encrypted `openssh-key-v1` blob.
    private static func decrypt(
        _ privateBlob: Data,
        cipher: String,
        kdf: String,
        kdfOptions: Data,
        passphrase: String
    ) throws -> Data {
        guard kdf == "bcrypt" else {
            throw KeyError.unsupported("the key uses the \(kdf) kdf, which this app cannot read")
        }
        let (key, iv) = try derivedKeyAndIV(kdfOptions: kdfOptions, cipher: cipher, passphrase: passphrase)
        guard let plain = AES.ctr([UInt8](privateBlob), key: key, iv: iv) else {
            throw KeyError.malformed("the key's cipher parameters were rejected")
        }
        return Data(plain)
    }

    // MARK: - Wire helpers

    /// SSH `string`: a uint32 length prefix followed by the raw bytes.
    private static func sshString(_ data: Data) -> Data {
        var out = Data()
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(data)
        return out
    }

    private static func uint32(_ value: UInt32) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }

    private struct Reader {
        private let data: Data
        private var index: Data.Index

        init(_ data: Data) {
            self.data = data
            self.index = data.startIndex
        }

        mutating func uint32() throws -> UInt32 {
            guard data.distance(from: index, to: data.endIndex) >= 4 else {
                throw KeyError.malformed("unexpected end of key")
            }
            var value: UInt32 = 0
            for _ in 0..<4 {
                value = (value << 8) | UInt32(data[index])
                index = data.index(after: index)
            }
            return value
        }

        mutating func string() throws -> Data {
            let length = Int(try uint32())
            guard data.distance(from: index, to: data.endIndex) >= length else {
                throw KeyError.malformed("string longer than remaining key data")
            }
            let end = data.index(index, offsetBy: length)
            defer { index = end }
            return data[index..<end]
        }
    }
}