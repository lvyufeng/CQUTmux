import SwiftUI
import CQUTTransport

/// The agent feed. Mirrors Moshi's Inbox: a host picker, pending approvals
/// with Allow / Deny, and a running log of what agents have been doing.
struct InboxView: View {
    @Environment(HostStore.self) private var store

    @State private var selectedHost: Host?
    @State private var client: HookClient?
    @State private var segment: Segment = .inbox

    private enum Segment: String, CaseIterable { case inbox = "Inbox", usages = "Usages" }

    var body: some View {
        Group {
            if store.hosts.isEmpty {
                ContentUnavailableView {
                    Label("No hosts", systemImage: "server.rack")
                } description: {
                    Text("Add a host on the Terminal tab, install cqutmux-hook on it, then pick it here.")
                }
            } else if let client {
                feed(client)
            } else {
                ContentUnavailableView {
                    Label("Pick a host", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("Choose which machine's agent feed to watch.")
                } actions: {
                    hostPicker
                }
            }
        }
        .navigationTitle("Inbox")
        .task {
            #if DEBUG
            if client == nil,
               let target = store.hosts.first(where: { $0.hostname == ProcessInfo.processInfo.environment["CQUT_DEV_HOST"] }) {
                connect(to: target)
            }
            #endif
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $segment) {
                    ForEach(Segment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    hostPicker
                } label: {
                    Label("Host", systemImage: "server.rack")
                }
            }
        }
    }

    @ViewBuilder
    private var hostPicker: some View {
        ForEach(store.hosts) { host in
            Button {
                connect(to: host)
            } label: {
                Text("\(host.displayName) — \(host.target)")
            }
        }
    }

    @ViewBuilder
    private func feed(_ client: HookClient) -> some View {
        switch segment {
        case .inbox:
            List {
                if case .failed(let message) = client.state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }
                if client.events.isEmpty {
                    Section {
                        Text(client.state == .connected ? "Waiting for agent activity…" : "Connecting to the host…")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                }
                ForEach(client.events) { event in
                    EventRow(event: event) { allow in
                        client.resolve(event, allow: allow)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { client.start() }
        case .usages:
            ContentUnavailableView {
                Label("Usages", systemImage: "gauge.with.dots.needle.50percent")
            } description: {
                Text("Rate-limit burn pace per agent lands here.")
            }
        }
    }

    private func connect(to host: Host) {
        client?.stop()
        selectedHost = host
        let seed = KeychainStore.load(account: host.keySeedAccount)
        let credential: SSHCredential
        if let seed {
            credential = .ed25519Seed(seed)
        } else if let password = KeychainStore.load(account: host.passwordAccount),
                  let text = String(data: password, encoding: .utf8) {
            credential = .password(text)
        } else {
            // Nothing stored yet — the Terminal tab is where credentials are entered.
            return
        }

        let configuration = TransportConfiguration(
            host: host.hostname, port: host.port, username: host.username, credential: credential
        )
        let client = HookClient(configuration: configuration)
        self.client = client
        client.start()
    }
}

private struct EventRow: View {
    let event: AgentEvent
    let resolve: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(event.isPending ? .orange : Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title.isEmpty ? event.sourceLabel : event.title)
                        .font(.subheadline.weight(.medium))
                    Text("\(event.sourceLabel) · \(relativeTime)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !event.body.isEmpty {
                Text(event.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            if event.isPending {
                HStack(spacing: 10) {
                    Button("Allow") { resolve(true) }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                    Button("Deny", role: .destructive) { resolve(false) }
                        .buttonStyle(.bordered)
                }
                .controlSize(.small)
            } else if let decision = event.decision {
                Label(decision == "allow" ? "Approved" : "Denied", systemImage: decision == "allow" ? "checkmark.circle" : "xmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch event.kind {
        case .approval: "hand.raised"
        case .notice: "bell"
        }
    }

    private var relativeTime: String {
        guard let date = event.date else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}