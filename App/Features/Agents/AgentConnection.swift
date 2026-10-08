import Foundation
import Observation
import CQUTTransport

/// App-level connection to one host's agent gateway, shared by the Inbox and
/// Code tabs so a single SSH session serves both.
@Observable
final class AgentConnection {
    private(set) var client: HookClient?
    private(set) var host: Host?
    private(set) var lastError: String?

    /// Mirrors pending approvals to a paired watch and applies its decisions.
    /// Lives here because this is where both the pending set and the resolver
    /// already are — the watch is a second view of the same connection.
    let watch = WatchBridge()

    func connect(to host: Host) {
        client?.stop()
        self.host = host
        lastError = nil
        watch.activate()

        let credential: SSHCredential
        if let seed = KeychainStore.load(account: host.keySeedAccount) {
            credential = .ed25519Seed(seed)
        } else if let data = KeychainStore.load(account: host.passwordAccount),
                  let text = String(data: data, encoding: .utf8) {
            credential = .password(text)
        } else {
            lastError = "No saved credentials for \(host.displayName). Connect once from the Terminal tab."
            client = nil
            return
        }

        let configuration = TransportConfiguration(
            host: host.hostname, port: host.port, username: host.username, credential: credential
        )
        let token = KeychainStore.load(account: host.gatewayTokenAccount)
            .flatMap { String(data: $0, encoding: .utf8) }
        let client = HookClient(configuration: configuration, remotePort: host.gatewayPort, token: token)

        // Keep the watch in step with whatever is pending here.
        client.onEventsChanged = { [weak self] events in
            self?.watch.publish(Self.snapshot(events))
        }
        watch.onDecision = { [weak self] id, allow in
            guard let self, let event = self.client?.events.first(where: { $0.id == id }) else { return }
            self.client?.resolve(event, allow: allow)
        }
        watch.onNeedSnapshot = { [weak self] in
            guard let self, let events = self.client?.events else { return }
            self.watch.publish(Self.snapshot(events))
        }

        // A push token belongs to the *host's* gateway, not to this app, so it
        // is re-registered on every connect: host A's gateway must not keep
        // pushing for a session that has moved to host B.
        PushCoordinator.shared.onToken = { [weak self] token in
            guard let self, let client = self.client else { return }
            Task { await client.registerPushToken(token) }
        }
        if let token = PushCoordinator.shared.deviceToken, token.isEmpty == false {
            Task { await client.registerPushToken(token) }
        }
        // Answering from a notification has to resolve through the same path
        // the Inbox and the watch use, or the decision would be local to the
        // phone and the agent would never hear it.
        PushCoordinator.shared.onRemoteDecision = { [weak self] id, allow in
            guard let self, let event = self.client?.events.first(where: { $0.id == id }) else { return }
            self.client?.resolve(event, allow: allow)
        }
        PushCoordinator.shared.onRemoteEvent = { [weak self] _ in
            self?.client?.refreshNow()
        }

        self.client = client
        client.start()
    }

    /// Only approvals that still need a decision are worth a watch buzz — a
    /// notice has nothing to act on from the wrist.
    private static func snapshot(_ events: [AgentEvent]) -> WatchPayload.Snapshot {
        WatchPayload.Snapshot(
            items: events.filter(\.isPending).map {
                .init(id: $0.id, source: $0.sourceLabel, title: $0.displayTitle, body: $0.displayBody)
            }
        )
    }
}