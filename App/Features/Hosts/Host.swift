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
    /// The key itself lives in the Keychain under `keySeedAccount`; nothing
    /// about it is persisted here. (An earlier `keyIdentifier` field pretended
    /// otherwise and was never written, so the form always read "None".)
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

    /// Which multiplexer this host's session command starts, if the command
    /// says. Read off `sessionCommand` rather than stored separately so the two
    /// cannot disagree — the command is what actually runs.
    ///
    /// Used to decide whether the window quick-access row is meaningful: the
    /// row sends tmux prefix-key keystrokes, so firing it at a zellij or herdr
    /// session would type a control character into whatever is running in the
    /// pane. `nil` is deliberately distinct from "not a mux": an unrecognised
    /// command might be a wrapper, and hiding the row is the safe half of that
    /// uncertainty.
    ///
    /// Matched as a *command word*, not as a substring, and that distinction
    /// is not hypothetical: the obvious `contains("tmux")` also matches our own
    /// default session name in `zellij attach -c cqutmux`, so every zellij
    /// host would have been handed a row of tmux keystrokes. The word is taken
    /// from the start of the command or from just after a shell separator, and
    /// compared as a path component so `/usr/bin/tmux` still counts.
    var mux: String? {
        // Split on the separators that end one command and start the next, so
        // `cd ~ && tmux new` is read as tmux.
        let words = sessionCommand
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || ";&|".contains($0) })
            .map { $0.split(separator: "/").last.map(String.init) ?? String($0) }
        for word in words {
            if let match = ["tmux", "zellij", "herdr"].first(where: { word == $0 || word == "\($0).exe" }) {
                return match
            }
        }
        return nil
    }

    var displayName: String { name.isEmpty ? hostname : name }
    var target: String { username.isEmpty ? hostname : "\(username)@\(hostname)" }

    /// Keychain account holding this host's gateway bearer token.
    var gatewayTokenAccount: String { "host.\(id.uuidString).gatewayToken" }
}