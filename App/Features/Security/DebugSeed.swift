#if DEBUG
import Foundation

/// Test-only seeding for UI runs: inject a host and an ed25519 seed through the
/// launch environment so a simulator build can be exercised without hand entry.
/// Compiled out of release builds entirely.
enum DebugSeed {
    static func apply(to store: HostStore) {
        let env = ProcessInfo.processInfo.environment
        guard let hostname = env["CQUT_DEV_HOST"] else { return }

        var host = Host()
        host.name = env["CQUT_DEV_NAME"] ?? hostname
        host.hostname = hostname
        host.port = Int(env["CQUT_DEV_PORT"] ?? "22") ?? 22
        host.username = env["CQUT_DEV_USER"] ?? ""
        host.authMethod = .key
        host.transport = .ssh
        host.sessionCommand = ""

        if let jump = env["CQUT_DEV_JUMP"], !jump.isEmpty {
            host.jumpHost = jump
        }

        if let seedB64 = env["CQUT_DEV_KEY_SEED"], let seed = Data(base64Encoded: seedB64) {
            KeychainStore.save(seed, account: host.keySeedAccount)
        }

        if let token = env["CQUT_DEV_GATEWAY_TOKEN"], let data = token.data(using: .utf8) {
            KeychainStore.save(data, account: host.gatewayTokenAccount)
        }

        if let port = env["CQUT_DEV_GATEWAY_PORT"], let value = Int(port) {
            host.gatewayPort = value
        }

        if !store.hosts.contains(where: { $0.hostname == host.hostname && $0.port == host.port }) {
            store.upsert(host)
        }
    }
}
#endif