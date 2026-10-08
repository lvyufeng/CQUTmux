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