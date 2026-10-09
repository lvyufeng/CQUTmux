import Foundation
import Observation
import CQUTTransport

/// Asks each saved host what its gateway is doing.
///
/// Deliberately a *probe* rather than a field on the connection: the Inbox only
/// knows about whichever host it is attached to, while the host list shows
/// every saved host at once and is exactly where you go when one of them stops
/// working. So this opens its own short-lived SSH connection per host, asks
/// once, and closes it — the check has to work for a host that is not
/// connected, which is the only case the dot exists for.
@Observable
@MainActor
final class GatewayProbe {
    private(set) var states: [String: GatewayState] = [:]
    /// In flight, so the row can show a spinner rather than the skeleton of an
    /// answer it does not have yet.
    private(set) var probing: Set<String> = []

    func state(for host: Host) -> GatewayState {
        states[host.id.uuidString] ?? .unknown
    }

    func isProbing(_ host: Host) -> Bool { probing.contains(host.id.uuidString) }

    /// Probes every host in the list, one at a time.
    ///
    /// Serial rather than parallel: each probe is an SSH handshake, and a phone
    /// opening five at once on a mobile network is a worse experience than
    /// watching five dots fill in.
    func probeAll(_ hosts: [Host]) async {
        for host in hosts {
            await probe(host)
        }
    }

    func probe(_ host: Host) async {
        guard !probing.contains(host.id.uuidString) else { return }
        guard let seed = host.resolveSeed() else {
            // No credentials means the probe cannot run at all, which is not
            // the same as the gateway being down. Leaving it unknown is honest;
            // guessing "not running" would send the user to fix the wrong thing.
            return
        }
        probing.insert(host.id.uuidString)
        defer { probing.remove(host.id.uuidString) }

        let credential: SSHCredential
        if let password = KeychainStore.load(account: host.passwordAccount),
           let text = String(data: password, encoding: .utf8) {
            credential = .password(text)
        } else {
            credential = .ed25519Seed(seed)
        }

        let transport = SSHTransport()
        var configuration = TransportConfiguration(
            host: host.hostname, port: host.port, username: host.username, credential: credential
        )
        configuration.applyIntegrationMarkers(IntegrationSettings())
        transport.connect(configuration, cols: 80, rows: 24)
        defer { transport.disconnect() }

        guard await waitForSession(transport) else {
            states[host.id.uuidString] = .notRunning
            return
        }
        states[host.id.uuidString] = await classify(host, transport: transport)
    }

    /// Waits for the SSH session to come up, giving up quickly.
    ///
    /// Short on purpose: the dot is a hint, and a probe that hangs for a minute
    /// holds the row in "checking" long past the point the user has stopped
    /// looking at it.
    private func waitForSession(_ transport: SSHTransport) async -> Bool {
        for _ in 0..<40 {
            if transport.hasActiveSession { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private func classify(_ host: Host, transport: SSHTransport) async -> GatewayState {
        // One round trip that answers everything: whether the tool exists where
        // it is, and what both the configured port and the default one say. A
        // single command rather than four, because the SSH channel is the slow
        // part and each extra `run` is another round trip on a phone network.
        let script = GatewayStatus.probeScript(ports: [host.gatewayPort, GatewayStatus.defaultPort])
        guard let result = await transport.run(script, timeout: 25) else {
            return .notRunning
        }
        return GatewayStatus.interpret(
            result.text,
            configuredPort: host.gatewayPort,
            exitCode: result.exitCode
        )
    }
}
