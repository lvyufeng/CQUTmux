import Foundation
import Observation

/// Directories the user has been in, most recent first.
///
/// Keyed by host, not global: `/srv/app` on two machines are two different
/// places, and a list that mixed them would offer a path that exists on one and
/// silently fails on the other. Keying by hostname and port rather than the
/// saved host's id means the list survives deleting and re-adding a host.
@Observable
final class RecentDirectoryStore {
    /// How many are kept. Enough to cover the handful of trees someone works in
    /// without turning the menu into a second file browser.
    static let limit = 12

    private var byHost: [String: [String]] = [:]
    private let defaults: UserDefaults
    private static let key = "cqutmux.recentDirectories"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// The key a host's list is filed under. Exposed so a caller can tell
    /// whether anything has been recorded without fetching the list.
    static func hostKey(_ host: Host) -> String { "\(host.hostname):\(host.port)" }

    func recent(for host: Host) -> [String] { byHost[Self.hostKey(host)] ?? [] }

    /// Records a visit. `.` is skipped: it is the root of every browse, so
    /// recording it would push a real directory off the end of the list every
    /// time someone started over.
    func record(_ path: String, for host: Host) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "." else { return }

        var list = byHost[Self.hostKey(host)] ?? []
        list.removeAll { $0 == trimmed }
        list.insert(trimmed, at: 0)
        byHost[Self.hostKey(host)] = Array(list.prefix(Self.limit))
        save()
    }

    func clear(for host: Host) {
        byHost.removeValue(forKey: Self.hostKey(host))
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return }
        byHost = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(byHost) else { return }
        defaults.set(data, forKey: Self.key)
    }
}