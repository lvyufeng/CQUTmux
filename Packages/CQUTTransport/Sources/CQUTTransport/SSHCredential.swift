import Foundation

/// How a session authenticates. Private keys are carried as raw ed25519 seeds,
/// never as the on-disk OpenSSH blob — the app stores those in the Keychain.
public enum SSHCredential: Sendable {
    case password(String)
    case ed25519Seed(Data)

    public var isKey: Bool {
        if case .ed25519Seed = self { return true }
        return false
    }
}