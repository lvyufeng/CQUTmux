import Foundation
import CQUTTransport

/// The stored form of a host's SSH key, and how it is turned back into a seed.
///
/// Why the key is sometimes stored encrypted
/// -----------------------------------------
/// The app used to keep only the 32-byte seed, which meant an encrypted key
/// could not be imported at all: the passphrase was needed once, at import
/// time, and never again. That is the friendliest arrangement — no passphrase
/// survives in the Keychain — but it silently discards the protection the user
/// chose when they created the key, and it is not what Moshi does.
///
/// So an encrypted key is kept as-is, and its passphrase beside it in the
/// Keychain, readable only when the device is unlocked. That makes the
/// passphrase a real second factor: reading the seed still requires the
/// passphrase, which is only in the Keychain, which is only readable on an
/// unlocked device. The app therefore does not re-derive anything at connect
/// time beyond what `CQUTTransport` already does.
///
/// The decisions live in this file, which imports only Foundation and the
/// transport package, so `scripts/passphrase-check.sh` can run the shipped code
/// rather than a copy of it.
enum KeyMaterial {
    /// What is stored under `keySeedAccount`.
    ///
    /// Older installs stored the bare 32-byte seed with no marker. Those are
    /// distinguished by *length*, not by a version byte: a seed is exactly 32
    /// bytes and a PEM is text, so `-----BEGIN` is unambiguous and a 32-byte
    /// blob can only be a seed. A version byte would have to be written by the
    /// old code to be read, which is precisely what it did not do.
    enum Stored: Equatable {
        /// A bare 32-byte ed25519 seed, imported unencrypted or generated here.
        case seed(Data)
        /// An `openssh-key-v1` PEM that needs a passphrase to open.
        case encryptedKey(String)
    }

    static func decode(_ data: Data) -> Stored? {
        if data.count == 32, !data.starts(with: Data("-----BEGIN".utf8)) {
            return .seed(data)
        }
        guard let text = String(data: data, encoding: .utf8),
              text.contains("BEGIN OPENSSH PRIVATE KEY") else { return nil }
        return .encryptedKey(text)
    }

    static func encode(_ stored: Stored) -> Data {
        switch stored {
        case .seed(let seed): seed
        case .encryptedKey(let pem): Data(pem.utf8)
        }
    }

    /// What a stored key needs before it can be used.
    enum Requirement: Equatable {
        /// A bare seed. Nothing more to ask for.
        case ready
        /// An encrypted key with its passphrase in the Keychain.
        case unlocked
        /// An encrypted key whose passphrase is not stored, or no longer opens
        /// it. The UI has to ask.
        case passphraseNeeded
        /// Nothing usable is stored.
        case missing
        /// Something is stored that is neither a seed nor an OpenSSH key.
        case unrecognised
    }

    /// Decides what to do, without prompting.
    ///
    /// The passphrase is tried even when one is stored, rather than trusting
    /// that a stored passphrase is the right one: the file could have been
    /// replaced under the same entry — a user re-importing a key rotated at the
    /// same path is exactly that — and reporting "unlocked" and then failing
    /// inside the SSH handshake is a much worse error than asking again.
    static func requirement(for data: Data?, passphrase: String?) -> Requirement {
        guard let data else { return .missing }
        switch decode(data) {
        case .seed:
            return .ready
        case .encryptedKey(let pem):
            guard let passphrase else { return .passphraseNeeded }
            do {
                _ = try Ed25519OpenSSH.seed(fromOpenSSHPrivateKey: pem, passphrase: passphrase)
                return .unlocked
            } catch {
                return .passphraseNeeded
            }
        case nil:
            return .unrecognised
        }
    }

    /// Opens a stored key, given whatever passphrase is available.
    static func seed(from data: Data?, passphrase: String?) throws -> Data {
        guard let data else { throw Failure.nothingStored }
        switch decode(data) {
        case .seed(let seed):
            return seed
        case .encryptedKey(let pem):
            guard let passphrase, !passphrase.isEmpty else { throw Failure.passphraseRequired }
            return try Ed25519OpenSSH.seed(fromOpenSSHPrivateKey: pem, passphrase: passphrase)
        case nil:
            throw Failure.unreadable
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case nothingStored
        case passphraseRequired
        case unreadable

        var description: String {
            switch self {
            case .nothingStored: "No key has been imported for this host yet."
            case .passphraseRequired: "This key is encrypted. Enter its passphrase to unlock it."
            case .unreadable: "The stored key is neither an ed25519 seed nor an OpenSSH private key."
            }
        }
    }
}