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
        _ = try reader.string() // kdf options
        if cipher != Data("none".utf8) || kdf != Data("none".utf8) {
            throw KeyError.unsupported("encrypted keys are not supported yet")
        }

        _ = try reader.uint32() // number of keys
        _ = try reader.string() // public key blob (redundant with the private half)

        let privateBlob = try reader.string()
        var pr = Reader(privateBlob)
        let check1 = try pr.uint32()
        let check2 = try pr.uint32()
        guard check1 == check2 else { throw KeyError.malformed("check integers differ") }

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

        var blob = Data("openssh-key-v1\u{0}".utf8)
        blob.append(sshString(Data("none".utf8)))   // cipher
        blob.append(sshString(Data("none".utf8)))   // kdf
        blob.append(sshString(Data()))              // kdf options: empty for none
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
        blob.append(sshString(privateBlob))

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