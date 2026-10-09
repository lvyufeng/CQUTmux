import Foundation
import Crypto

/// How a session authenticates. Private keys are carried as raw ed25519 seeds,
/// never as the on-disk OpenSSH blob — the app stores those in the Keychain.
public enum SSHCredential: Sendable {
    case password(String)
    case ed25519Seed(Data)

    public var isKey: Bool {
        if case .ed25519Seed = self { return true }
        return false
    }

    /// The key this connection can offer over a forwarded agent, if any.
    ///
    /// Password authentication has nothing to forward, which is why the
    /// connection form only shows the switch for key auth — and why this
    /// returns nil rather than inventing an identity.
    public var agentIdentity: SSHAgent.Identity? {
        guard case .ed25519Seed(let seed) = self,
              let publicKey = try? Ed25519OpenSSH.publicKey(fromSeed: seed)
        else { return nil }
        return SSHAgent.Identity(
            comment: "cqutmux",
            publicKeyOpenSSH: publicKey,
            algorithm: .ed25519
        )
    }

    /// A signer over the seed in this credential, for a forwarded agent.
    ///
    /// The seed is already in hand — it was unlocked to make the connection —
    /// so this closes over it rather than going back to the Keychain per
    /// signature. Nothing else holds a copy: the closure lives only as long as
    /// the transport does.
    public static func agentSigner(for credential: SSHCredential) -> SSHAgent.Signer? {
        guard case .ed25519Seed(let seed) = credential else { return nil }
        return { data, algorithm in
            guard case .ed25519 = algorithm else {
                throw SSHAgent.AgentError.unsupportedAlgorithm("\(algorithm)")
            }
            // The agent protocol has no algorithm negotiation: it signs the
            // bytes it is handed, and the SSH layer above has already hashed
            // them if the algorithm wants a hash. Ed25519 does not.
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            return try key.signature(for: data)
        }
    }
}