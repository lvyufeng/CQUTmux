import Foundation
import Security
import CQUTTransport

/// Thin wrapper over the iOS Keychain for per-host secrets.
/// Secrets never touch the host JSON file — only opaque identifiers do.
enum KeychainStore {
    private static let service = "app.cqutmux.ios"

    @discardableResult
    static func save(_ data: Data, account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        // Keys require biometrics to read; passwords are readable while unlocked.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

extension Host {
    var passwordAccount: String { "password.\(self.id.uuidString)" }
    var keySeedAccount: String { "keyseed.\(self.id.uuidString)" }
    /// The passphrase an imported private key was encrypted with, when the user
    /// chose to remember it. Stored beside the seed rather than alongside it
    /// inside the file: the app keeps the bare 32-byte seed, and keeping the
    /// passphrase separate means changing it does not require rewriting a key.
    var keyPassphraseAccount: String { "keypass.\(self.id.uuidString)" }

    /// The stored passphrase, or nil when none is kept.
    var keyPassphrase: String? {
        KeychainStore.load(account: keyPassphraseAccount)
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// This host's seed, opening an encrypted key with whatever passphrase is
    /// stored.
    ///
    /// nil means "not usable right now", not "no key": an encrypted key whose
    /// passphrase was not remembered is stored and valid, and the caller's
    /// correct response is to send the user to the connect flow — which does
    /// prompt — rather than to report that no key exists. Callers that report
    /// the distinction (the gateway dots) say "unknown"; the ones that cannot
    /// (a terminal that has to authenticate now) fail a connection that the
    /// connect flow would have completed.
    func resolveSeed() -> Data? {
        try? KeyMaterial.seed(from: KeychainStore.load(account: keySeedAccount), passphrase: keyPassphrase)
    }
}