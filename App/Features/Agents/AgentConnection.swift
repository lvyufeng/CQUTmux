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

    /// The slow usage poll. Held so reconnecting to another host replaces it
    /// rather than leaving two timers pushing different hosts' numbers.
    private var usageTask: Task<Void, Never>?

    func connect(to host: Host) {
        client?.stop()
        usageTask?.cancel()
        self.host = host
        lastError = nil
        watch.activate()

        let credential: SSHCredential
        if let seed = host.resolveSeed() {
            credential = .ed25519Seed(seed)
        } else if let data = KeychainStore.load(account: host.passwordAccount),
                  let text = String(data: data, encoding: .utf8) {
            credential = .password(text)
        } else {
            lastError = "No saved credentials for \(host.displayName). Connect once from the Terminal tab."
            client = nil
            return
        }

        var configuration = TransportConfiguration(
            host: host.hostname, port: host.port, username: host.username, credential: credential
        )
        // The gateway connection runs commands on the host too, so the marker
        // belongs here as much as in the terminal — an rc file that branches on
        // it sees a consistent answer either way.
        configuration.applyIntegrationMarkers(IntegrationSettings())
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
        // A question answered from the wrist goes through the same resolve the
        // Inbox uses, so both surfaces record the same thing on the host.
        watch.onAnswer = { [weak self] id, answer in
            guard let self, let event = self.client?.events.first(where: { $0.id == id }) else { return }
            self.client?.resolve(event, answer: answer)
        }
        watch.onNeedSnapshot = { [weak self] in
            guard let self, let events = self.client?.events else { return }
            self.watch.publish(Self.snapshot(events))
        }
        // Usage is polled rather than evented: the host's rate-limit counters
        // move over minutes, and the watch re-reads the last value from its
        // application context when it wakes, so a slow cadence is enough.
        watch.onNeedUsage = { [weak self] in
            guard let self else { return }
            Task { await self.publishUsage() }
        }
        usageTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.publishUsage()
                try? await Task.sleep(for: .seconds(180))
            }
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

    /// Fetches the usage board and flattens it onto the watch's model.
    ///
    /// Failure is silent on purpose: a watch showing the last good reading
    /// beats one showing an error the wearer cannot act on, and the phone's own
    /// Usages tab is where a broken endpoint is worth reporting.
    @MainActor
    private func publishUsage() async {
        guard let client, client.state == .connected else { return }
        guard let board = try? await client.usage() else { return }
        watch.publishUsage(Self.usage(board))
    }

    /// Only approvals that still need a decision are worth a watch buzz — a
    /// notice has nothing to act on from the wrist.
    /// Built by field rather than encoded from `UsageBoard`, because the two
    /// types live in different targets on purpose: the watch links no
    /// transport, so it cannot see `HookClient`'s model at all.
    private static func usage(_ board: UsageBoard) -> WatchPayload.Usage {
        WatchPayload.Usage(
            entries: board.entries.map { entry in
                .init(
                    source: entry.source,
                    label: entry.label,
                    pace: entry.pace,
                    windows: entry.windows.map {
                        .init(label: $0.label, percent: $0.percent, resetIn: $0.resetIn)
                    }
                )
            },
            generatedAt: ISODate.parse(board.generatedAt ?? "")
        )
    }

    private static func snapshot(_ events: [AgentEvent]) -> WatchPayload.Snapshot {
        WatchPayload.Snapshot(
            items: events.filter(\.isPending).map {
                .init(
                    id: $0.id,
                    source: $0.sourceLabel,
                    title: $0.displayTitle,
                    body: $0.displayBody,
                    options: $0.options.map { .init(label: $0.label, value: $0.value) }
                )
            }
        )
    }
}