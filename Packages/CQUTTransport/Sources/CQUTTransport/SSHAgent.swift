import Foundation
import Crypto
import NIOCore
import NIOSSH

/// An ssh-agent, in the app, serving the one key the connection was made with.
///
/// This is what Moshi's "Forward SSH Agent" switch actually is, and it is worth
/// being precise about because the name suggests something it is not. It does
/// not bridge to an agent running elsewhere, and it does not need an agent
/// socket on the device — iOS has neither. It serves *the private key stored
/// for this connection* over the `auth-agent@openssh.com` channel the server
/// opens back to us, so that `git push` on the remote host can authenticate as
/// this user without a copy of the key ever being written to that host.
///
/// The protocol is OpenSSH's agent protocol (PROTOCOL.agent): a length-prefixed
/// message of a one-byte type, then type-specific fields. Only three messages
/// matter here, and short ones:
///
///   - `SSH2_AGENTC_REQUEST_IDENTITIES` → `SSH2_AGENT_IDENTITIES_ANSWER`
///   - `SSH2_AGENTC_SIGN_REQUEST`       → `SSH2_AGENT_SIGN_RESPONSE`
///   - anything else                    → `SSH_AGENT_FAILURE`
///
/// The subtlety is the signature format. The agent protocol predates RFC 4254
/// and asks for a raw algorithm-specific signature — 64 bytes of r‖s for
/// ECDSA, no ASN.1 wrapper — whereas SSH's `SSH2_MSG_USERAUTH_REQUEST` wants a
/// length-prefixed string containing a proper `ssh-ecdsa` blob. CryptoKit
/// hands back the raw form, so this file builds the blob rather than
/// stripping a wrapper, which is the direction that is easy to get wrong.
public final class SSHAgent {
    /// One key, because that is what a connection has — and Moshi's docs are
    /// explicit that it forwards "exactly one identity".
    public struct Identity {
        public var comment: String
        public var publicKeyOpenSSH: String
        public var algorithm: Algorithm

        public enum Algorithm: Sendable {
            case ed25519
            case ecdsaP256
            case ecdsaP384
            case ecdsaP521
            case rsa
        }

        public init(comment: String, publicKeyOpenSSH: String, algorithm: Algorithm) {
            self.comment = comment
            self.publicKeyOpenSSH = publicKeyOpenSSH
            self.algorithm = algorithm
        }
    }

    public enum AgentError: Error, CustomStringConvertible {
        case noIdentity
        case unsupportedAlgorithm(String)
        case signingFailed(String)
        case malformedRequest

        public var description: String {
            switch self {
            case .noIdentity:
                "no key is available to forward"
            case .unsupportedAlgorithm(let name):
                "forwarding is not implemented for \(name) keys"
            case .signingFailed(let message):
                message
            case .malformedRequest:
                "the server sent a malformed agent request"
            }
        }
    }

    /// What the agent needs to sign. Returning raw bytes keeps the key material
    /// itself out of this type — the Keychain lookup and the `Crypto` call both
    /// live behind this closure, so nothing here ever holds a private key.
    public typealias Signer = @Sendable (Data, Identity.Algorithm) throws -> Data

    private let identity: Identity
    private let sign: Signer

    public init(identity: Identity, sign: @escaping Signer) {
        self.identity = identity
        self.sign = sign
    }

    // MARK: - Message numbers

    private enum Message: UInt8 {
        case requestIdentities = 11
        case identitiesAnswer = 12
        case signRequest = 13
        case signResponse = 14
        case failure = 5
    }

    /// One request in, one reply out.
    ///
    /// The framing is stripped by the caller: this takes the payload after the
    /// 4-byte length prefix and returns a payload for the caller to prefix.
    /// That split is what lets the channel handler be a thin adapter and this
    /// be testable on its own, which matters because it is the part with the
    /// signature-format trap in it.
    ///
    /// Throws when a request is malformed or a signature cannot be produced.
    /// `reply(for:)` is the wire-facing form of this, and is what sends.
    ///
    /// The reply for one request, with every failure turned into
    /// `SSH_AGENT_FAILURE`.
    ///
    /// This is the form the channel uses, and the reason the conversion lives
    /// here rather than in the handler is not style: the handler needs a live
    /// event loop to exercise, so a rule kept there is a rule nothing checks.
    /// `handle` throws for a caller that wants to know why; this one is for the
    /// wire, where the only useful answer to a request we cannot serve is the
    /// protocol's own failure message. Dying instead would break `git` on the
    /// host in a way that looks like the network rather than like us.
    public func reply(for payload: Data) -> Data {
        (try? handle(payload)) ?? Data([Message.failure.rawValue])
    }

    public func handle(_ payload: Data) throws -> Data {
        var reader = AgentReader(payload)
        guard let type = reader.byte().flatMap(Message.init(rawValue:)) else {
            throw AgentError.malformedRequest
        }

        switch type {
        case .requestIdentities:
            return identitiesAnswer()
        case .signRequest:
            return try signResponse(reader)
        case .identitiesAnswer, .signResponse, .failure:
            // Server-to-agent messages. A peer sending one is confused; the
            // protocol's answer to confusion is SSH_AGENT_FAILURE.
            return Data([Message.failure.rawValue])
        }
    }

    /// `SSH2_AGENT_IDENTITIES_ANSWER`: a count, then that many (blob, comment)
    /// pairs. The blob is the key in SSH's own wire format, which is what the
    /// server hands to `authorized_keys` — not the OpenSSH text form.
    private func identitiesAnswer() -> Data {
        guard let blob = Self.wireBlob(publicKeyOpenSSH: identity.publicKeyOpenSSH) else {
            return Data([Message.failure.rawValue])
        }
        var writer = AgentWriter()
        writer.byte(Message.identitiesAnswer.rawValue)
        writer.uint32(1)
        writer.string(blob)
        writer.string(Data(identity.comment.utf8))
        return writer.data
    }

    private func signResponse(_ reader: AgentReader) throws -> Data {
        var reader = reader
        guard let keyBlob = reader.string(), let data = reader.string() else {
            throw AgentError.malformedRequest
        }
        // The flags and the key they ask about are both ignored: there is one
        // identity, so a request that names a different key could only be the
        // server asking about a key we never offered.
        _ = reader.uint32()

        guard let expected = Self.wireBlob(publicKeyOpenSSH: identity.publicKeyOpenSSH) else {
            return Data([Message.failure.rawValue])
        }
        guard keyBlob == expected else { return Data([Message.failure.rawValue]) }

        let raw = try sign(data, identity.algorithm)
        guard let signature = Self.signatureBlob(raw: raw, algorithm: identity.algorithm) else {
            throw AgentError.unsupportedAlgorithm("\(identity.algorithm)")
        }

        var writer = AgentWriter()
        writer.byte(Message.signResponse.rawValue)
        writer.string(signature)
        return writer.data
    }

    // MARK: - Wire formats

    /// The public key in SSH wire format, from its OpenSSH text form.
    ///
    /// `ssh-ed25519 AAAAC3…` is a base64 of the *complete* wire blob — the
    /// algorithm name and the key bytes, each length-prefixed, in that order.
    /// The text form is self-describing, so the blob is the decode and nothing
    /// more; prefixing the algorithm name again is the mistake this function
    /// exists to avoid, and it produces a key that parses and is then rejected
    /// by `authorized_keys` for reasons the server never explains.
    ///
    /// Decoding the text rather than re-deriving from the private key is
    /// deliberate: the blob must match byte for byte what the server already
    /// has, and the text form is the copy that was checked.
    public static func wireBlob(publicKeyOpenSSH: String) -> Data? {
        let parts = publicKeyOpenSSH.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        // The base64 could hold anything; the algorithm named in the text must
        // be the one inside the blob, or two different keys are being confused.
        var reader = AgentReader(blob)
        guard let name = reader.string(), name == Data(parts[0].utf8) else { return nil }
        return blob
    }

    /// Wraps a raw signature into the length-prefixed blob the agent protocol
    /// and `SSH2_MSG_USERAUTH_REQUEST` both expect.
    ///
    /// The two families differ in exactly the way that bites:
    ///   - Ed25519 signs the message directly and the algorithm name is the
    ///     whole signature.
    ///   - ECDSA signs a hash, and OpenSSH's agent protocol wants the raw
    ///     r‖s pair with no ASN.1 — but CryptoKit's `ECDSASignature.rawRepresentation`
    ///     is already r‖s, so the ASN.1 stripping other implementations need is
    ///     not required here.
    ///   - RSA is refused rather than half-done: OpenSSH wants the full
    ///     PKCS#1 v1.5 blob including DER, and a wrong answer here would look
    ///     like a rejected key rather than a bug in us.
    public static func signatureBlob(raw: Data, algorithm: Identity.Algorithm) -> Data? {
        let name: String
        switch algorithm {
        case .ed25519: name = "ssh-ed25519"
        case .ecdsaP256: name = "ecdsa-sha2-nistp256"
        case .ecdsaP384: name = "ecdsa-sha2-nistp384"
        case .ecdsaP521: name = "ecdsa-sha2-nistp521"
        case .rsa: return nil
        }

        var writer = AgentWriter()
        writer.string(Data(name.utf8))
        if case .ed25519 = algorithm {
            writer.string(raw)
        } else {
            // The inner blob is r‖s as two MPI-ish fixed-width integers, which
            // for these curves is exactly half the raw representation each.
            let half = raw.count / 2
            guard half > 0, raw.count % 2 == 0 else { return nil }
            var inner = AgentWriter()
            inner.string(raw.prefix(half))
            inner.string(raw.suffix(half))
            writer.string(inner.data)
        }
        return writer.data
    }
}

/// Reads the agent protocol's fields. Only what the three supported messages
/// touch — the point is to read them correctly, not completely.
public struct AgentReader {
    private let data: Data
    private var offset: Int

    public init(_ data: Data) {
        self.data = data
        self.offset = 0
    }

    public mutating func byte() -> UInt8? {
        guard offset < data.count else { return nil }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    public mutating func uint32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let start = data.startIndex + offset
        offset += 4
        return data[start..<start + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    public mutating func string() -> Data? {
        guard let length = uint32() else { return nil }
        // Bounded before allocating: the length comes off the wire, and
        // trusting it would let a malformed message ask for a huge allocation.
        guard length <= 1 << 20, offset + Int(length) <= data.count else { return nil }
        let start = data.startIndex + offset
        offset += Int(length)
        return data[start..<start + Int(length)]
    }
}

/// Writes the same fields. `uint32` first everywhere is what makes the format
/// self-describing, and getting the order wrong is the usual reason an agent
/// answers with something a server silently rejects.
public struct AgentWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func byte(_ value: UInt8) {
        data.append(value)
    }

    public mutating func uint32(_ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    public mutating func string(_ value: Data) {
        uint32(UInt32(value.count))
        data.append(value)
    }
}