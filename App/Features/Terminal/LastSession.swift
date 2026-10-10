import Foundation
import Observation

/// The multiplexer session the user was last in on a host.
struct LastSession: Codable, Hashable {
    var mux: String
    var name: String
    /// How the mux addresses the window. A string because herdr uses a tab id
    /// (`w1:t2`), not a number — the same reason the picker carries one.
    var window: String?
}

/// Whether to resume, and what that resume is.
///
/// Decided here, apart from the view, because the two failure modes are both
/// silent. Resuming when it should not — the user deliberately walked out of a
/// session to a bare shell, closed the app, and comes back into something they
/// left — reads as the app ignoring them. Failing to resume when it should looks
/// identical to a feature that was never built: the terminal simply opens on the
/// shell and nothing says why.
enum SessionResume {
    enum Action: Equatable {
        /// Attach to the remembered session, optionally landing on a window.
        case restore(LastSession, window: String?)
        /// Nothing to do: no session recorded, resuming is off, a link is about
        /// to drive the session itself, or the current session *is* the one
        /// that would be restored.
        case none
    }

    /// The one place the decision is made.
    ///
    /// `current` is what this terminal is already attached to, if anything —
    /// passed in rather than read from the store, because resuming onto the
    /// session already on screen is a no-op that would nevertheless type an
    /// attach command into a live pane.
    ///
    /// `hasLink` suppresses resuming: a `cqutmux://tmux?…` link *is* the
    /// instruction about which session to be in, and following it is what the
    /// user asked for. Resuming over the top of it would fight the link — and
    /// the link arrives on the same "shell is up" signal, so the two would race.
    static func action(hasLink: Bool, last: LastSession?, current: LastSession?) -> Action {
        guard !hasLink, let last else { return .none }
        // Already there: re-attaching would send a command into the pane that
        // is running whatever the user is actually doing.
        if let current, current == last { return .none }
        return .restore(last, window: last.window)
    }
}

/// Remembers the last session per host, in `UserDefaults`.
///
/// Keyed by hostname and port rather than the saved host's id, the same way
/// `RecentDirectoryStore` is: re-pairing a host creates a new id, and a resume
/// that forgot the session because the host was re-added would be a resume that
/// never worked after the one operation a user performs when a host is fixed.
@Observable
final class LastSessionStore {
    private var byHost: [String: LastSession] = [:]
    private let defaults: UserDefaults
    private static let key = "cqutmux.lastSessions"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    static func hostKey(_ host: Host) -> String { "\(host.hostname):\(host.port)" }

    func last(for host: Host) -> LastSession? { byHost[Self.hostKey(host)] }

    /// Records where the user attached. Called from the session picker, so the
    /// remembered value is always a session the user chose on purpose.
    func record(_ session: LastSession, for host: Host) {
        guard !session.name.isEmpty else { return }
        byHost[Self.hostKey(host)] = session
        save()
    }

    func clear(for host: Host) {
        byHost.removeValue(forKey: Self.hostKey(host))
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([String: LastSession].self, from: data)
        else { return }
        byHost = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(byHost) else { return }
        defaults.set(data, forKey: Self.key)
    }
}