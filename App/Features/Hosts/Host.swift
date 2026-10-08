import Foundation

/// Transport preference, mirroring Moshi's four connection types.
/// `auto` tries mosh, then ET, then SSH.
enum TransportKind: String, Codable, CaseIterable, Identifiable {
    case auto, ssh, mosh, et

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .ssh: "SSH"
        case .mosh: "Mosh"
        case .et: "ET"
        }
    }

    var detail: String {
        switch self {
        case .auto: "Tries mosh, then ET, then SSH."
        case .ssh: "Plain SSH. Works where UDP is blocked."
        case .mosh: "UDP transport that survives roaming and sleep."
        case .et: "Eternal Terminal over TCP. Reconnects behind strict networks."
        }
    }
}

enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case password, key

    var id: String { rawValue }
    var label: String { self == .password ? "Password" : "SSH Key" }
}

struct Host: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var hostname: String = ""
    var port: Int = 22
    var username: String = ""
    var authMethod: AuthMethod = .password
    /// Keychain item reference for the private key. Never the key material itself.
    var keyIdentifier: String? = nil
    var transport: TransportKind = .auto
    var jumpHost: String? = nil            // "user@host:22"
    var moshPortRange: String? = nil
    var etPort: Int? = nil                 // defaults to 2022
    var forwardAgent: Bool = false
    /// Bearer token required by `cqutmux-hook --token`, if the host sets one.
    /// Stored in the Keychain, not here.
    var gatewayTokenIdentifier: String? = nil

    /// Port the host gateway listens on. Matches the daemon's default.
    var gatewayPort: Int = 24543

    /// Command tmux/multiplexer bootstrap runs on connect.
    var sessionCommand: String = "tmux new -A -s cqutmux"

    var displayName: String { name.isEmpty ? hostname : name }
    var target: String { username.isEmpty ? hostname : "\(username)@\(hostname)" }

    /// Keychain account holding this host's gateway bearer token.
    var gatewayTokenAccount: String { "host.\(id.uuidString).gatewayToken" }
}