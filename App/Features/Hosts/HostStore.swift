import Foundation
import Observation

/// Persists hosts to Application Support. Key material is kept out of here —
/// only a Keychain identifier is stored. See `CQUTSecurity` (Phase 1).
@Observable
final class HostStore {
    private(set) var hosts: [Host] = []

    private let fileURL: URL

    init(filename: String = "hosts.json") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent(filename)
        load()
    }

    func upsert(_ host: Host) {
        if let idx = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[idx] = host
        } else {
            hosts.append(host)
        }
        save()
    }

    func delete(_ host: Host) {
        hosts.removeAll { $0.id == host.id }
        save()
    }

    /// Saves a host from a pairing link, key material included.
    ///
    /// Kept here rather than in the view because it writes the Keychain and the
    /// host list together: a host saved without its key authenticates by
    /// password and fails, and a key saved without its host is an orphan the
    /// delete path will never clean up.
    ///
    /// An existing host at the same address is updated rather than duplicated.
    /// Re-pairing is how a host that rotated its key is fixed, and a second
    /// entry with the same address would leave the stale one in the list.
    @discardableResult
    func pair(with payload: Pairing.Payload) -> Host? {
        let existing = hosts.first {
            $0.hostname.caseInsensitiveCompare(payload.host) == .orderedSame
                && $0.port == payload.port
                && $0.username == payload.username
        }
        var host = existing ?? Host()
        host.hostname = payload.host
        host.port = payload.port
        host.username = payload.username
        if let name = payload.name, !name.isEmpty { host.name = name }
        else if host.name.isEmpty { host.name = payload.host }
        // Pairing always hands over a key, so the connection should try it.
        if payload.seed != nil { host.authMethod = .key }

        // Only write what the link carried. A link without a key must not clear
        // a key that is already there — the host may pair again later simply to
        // pick up a new token, and silently forgetting the key would turn that
        // into an authentication failure.
        if let seed = payload.seed {
            KeychainStore.save(seed, account: host.keySeedAccount)
        }
        if let token = payload.token, let data = token.data(using: .utf8) {
            KeychainStore.save(data, account: host.gatewayTokenAccount)
        }

        upsert(host)
        return host
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        hosts = (try? JSONDecoder().decode([Host].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(hosts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}