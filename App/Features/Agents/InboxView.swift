import SwiftUI

/// The agent feed. Mirrors Moshi's Inbox: a host picker, pending approvals
/// with Allow / Deny, and a running log of what agents have been doing.
struct InboxView: View {
    @Environment(HostStore.self) private var store
    @Environment(AgentConnection.self) private var connection

    @State private var segment: Segment = .inbox
    @State private var activity = ActivityManager()
    @State private var ledger = NotificationLedger()
    @State private var sawFirstPage = false

    private enum Segment: String, CaseIterable { case inbox = "Inbox", usages = "Usages" }

    var body: some View {
        Group {
            if store.hosts.isEmpty {
                ContentUnavailableView {
                    Label("No hosts", systemImage: "server.rack")
                } description: {
                    Text("Add a host on the Terminal tab, install cqutmux-hook on it, then pick it here.")
                }
            } else if let client = connection.client {
                feed(client)
            } else {
                ContentUnavailableView {
                    Label("Pick a host", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text(connection.lastError ?? "Choose which machine's agent feed to watch.")
                } actions: {
                    hostMenu
                }
            }
        }
        .navigationTitle("Inbox")
        .task {
            #if DEBUG
            if connection.client == nil,
               let target = store.hosts.first(where: { $0.hostname == ProcessInfo.processInfo.environment["CQUT_DEV_HOST"] }) {
                connection.connect(to: target)
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
                Menu { hostMenu } label: {
                    Label("Host", systemImage: "server.rack")
                }
            }
        }
    }

    @ViewBuilder
    private var hostMenu: some View {
        ForEach(store.hosts) { host in
            Button("\(host.displayName) — \(host.target)") {
                connection.connect(to: host)
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
                        // A connected client with nothing to show is either
                        // genuinely idle or failing to read the gateway, and
                        // those look identical without the error. "Waiting for
                        // agent activity" while every poll times out is the one
                        // message that sends someone looking in the wrong place.
                        if let error = client.lastError {
                            Text("Connected, but the gateway is not answering: \(error)")
                                .foregroundStyle(.orange)
                                .font(.footnote)
                        } else {
                            Text(client.state == .connected ? "Waiting for agent activity…" : "Connecting to the host…")
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                        }
                    }
                }
                ForEach(client.events) { event in
                    EventRow(event: event) { allow in
                        client.resolve(event, allow: allow)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .onChange(of: client.events) { _, events in
                let hostName = connection.host?.displayName ?? "Host"
                activity.update(hostName: hostName, events: events)
                let fresh = ledger.fresh(from: events, isFirstLoad: !sawFirstPage)
                sawFirstPage = true
                if !fresh.isEmpty { Task { await ApprovalNotifier.notify(fresh, hostName: hostName) } }
            }
        case .usages:
            ContentUnavailableView {
                Label("Usages", systemImage: "gauge.with.dots.needle.50percent")
            } description: {
                Text("Rate-limit burn pace per agent lands here.")
            }
        }
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
                    Text(event.displayTitle.isEmpty ? event.sourceLabel : event.displayTitle)
                        .font(.subheadline.weight(.medium))
                    Text("\(event.sourceLabel) · \(relativeTime)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !event.displayBody.isEmpty {
                Text(event.displayBody)
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
                Label(decision == "allow" ? "Approved" : "Denied",
                      systemImage: decision == "allow" ? "checkmark.circle" : "xmark.circle")
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