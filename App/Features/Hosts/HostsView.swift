import SwiftUI

struct HostsView: View {
    @Environment(ThemeStore.self) private var themes
    /// A link that named a host or a session. Held by the shell rather than
    /// here because a link can arrive before this view exists.
    var pendingLink: DeepLink?

    @Environment(HostStore.self) private var store
    @Environment(GatewayProbe.self) private var probe
    @State private var editing: Host?
    /// The host whose status sheet is open, if any.
    @State private var statusHost: Host?
    @State private var path: [Host] = []
    @State private var pairing = false

    /// A pairing link to open the sheet with, for a debug run. See
    /// `PairingView.initialText`.
    private var pairingLink: String {
        #if DEBUG
        ProcessInfo.processInfo.environment["CQUT_DEV_PAIR_LINK"] ?? ""
        #else
        ""
        #endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
        }
    }

    private var content: some View {
        List {
            if store.hosts.isEmpty {
                ContentUnavailableView {
                    Label("No hosts yet", systemImage: "server.rack")
                } description: {
                    Text("Add a Mac, Linux box, WSL or VPS to open a terminal session.")
                } actions: {
                    Button("Pair a Host") { pairing = true }
                        .buttonStyle(.borderedProminent)
                    Button("Add Manually") { editing = Host() }
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(store.hosts) { host in
                    NavigationLink(value: host) {
                        HostRow(host: host) { statusHost = host }
                    }
                }
                .onDelete { indexSet in
                    indexSet.map { store.hosts[$0] }.forEach(store.delete)
                }
            }
        }
        .navigationTitle("Terminal")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    // Pairing first: it is the path with no typing in it, and
                    // the one the host's `cqutmux pair` command produces.
                    Button {
                        pairing = true
                    } label: {
                        Label("Pair a Host", systemImage: "qrcode.viewfinder")
                    }
                    Button {
                        editing = Host()
                    } label: {
                        Label("Add Manually", systemImage: "square.and.pencil")
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $pairing) {
            PairingView(initialText: pairingLink) { payload in
                if let host = store.pair(with: payload) {
                    // Straight into the session: the whole point of pairing is
                    // that nothing else has to be filled in, so a screen that
                    // then asks the user to tap the host would be a step the
                    // feature exists to remove.
                    path = [host]
                }
            }
        }
        .navigationDestination(for: Host.self) { host in
            ConnectFlowView(host: host, link: pendingLink)
        }
        // A link opens the terminal on the host it names, or on the only host
        // there is. A link naming a host that is not saved says so rather than
        // doing nothing, because "I clicked a link and the app just sat there"
        // is the failure people blame on the app.
        .task(id: pendingLink) {
            guard let link = pendingLink else { return }
            let named: String?
            if case .host(let value) = link.target { named = value } else { named = nil }
            let match: Host?
            if let named {
                match = store.hosts.first {
                    $0.hostname.caseInsensitiveCompare(named) == .orderedSame
                        || $0.displayName.caseInsensitiveCompare(named) == .orderedSame
                }
            } else {
                match = store.hosts.count == 1 ? store.hosts.first : nil
            }
            guard let match else { return }
            if !path.contains(match) { path.append(match) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = Host()
                } label: {
                    Label("Add Host", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editing) { host in
            NavigationStack {
                HostEditView(host: host) { store.upsert($0) }
            }
        }
        .sheet(item: $statusHost) { host in
            HostStatusSheet(host: host)
        }
        // Probed when the list appears rather than on a timer: the dot answers
        // "is this host usable right now", and a stale answer to that is worse
        // than none — it would send someone to fix a gateway that came back up
        // ten minutes ago.
        .task { await probe.probeAll(store.hosts) }
        .task {
            #if DEBUG
            if !pairingLink.isEmpty { pairing = true }
            // Seeding a host and opening a session to it are separate things.
            // A run that wants to look at the list itself — the gateway status
            // dot, which is only visible when nothing is connected — says so.
            if ProcessInfo.processInfo.environment["CQUT_DEV_NO_CONNECT"] != "1",
               path.isEmpty,
               let target = store.hosts.first(where: { $0.hostname == ProcessInfo.processInfo.environment["CQUT_DEV_HOST"] }) {
                path = [target]
            }
            #endif
        }
    }
}

private struct HostRow: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(GatewayProbe.self) private var probe
    let host: Host
    /// Opens the fix sheet. Passed in rather than a sheet on this row, so the
    /// list presents one sheet rather than one per row.
    var onShowStatus: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(themes.current.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName).font(.body.weight(.medium))
                // String(port) avoids SwiftUI's locale grouping ("2,222").
                Text(verbatim: "\(host.target):\(String(host.port)) · \(host.transport.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HostStatusDot(host: host, onTap: onShowStatus)
        }
    }
}

/// The gateway's state as a dot, tappable for the fix.
///
/// Here rather than in Settings → Support because this list is where you are
/// when a host stops working: the Support screen asks about one host you have
/// already connected to, and the case this exists for is the one that is *not*
/// connected. A dot alone would say "something is wrong" and leave the user to
/// guess which of five things; the tap names it and gives the command.
private struct HostStatusDot: View {
    @Environment(GatewayProbe.self) private var probe
    let host: Host
    var onTap: () -> Void = {}

    var body: some View {
        let state = probe.state(for: host)
        Button(action: onTap) {
            if probe.isProbing(host) {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(state.isUp ? Self.color(for: state) : .clear)
                    .frame(width: 10, height: 10)
                    // Filled once the gateway has answered, hollow while the
                    // probe is still out: a dot that looks the same whether or
                    // not it has been checked is a dot that lies for the first
                    // few seconds of every visit to this screen.
                    .overlay {
                        Circle().strokeBorder(Self.color(for: state), lineWidth: 2)
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Gateway: \(state.label)")
        .accessibilityHint(state.fix.map { "Double tap for the fix: \($0)" } ?? state.detail)
    }

    static func color(for state: GatewayState) -> Color {
        switch state {
        case .running: .green
        case .unknown: .secondary
        case .update: .yellow
        case .wrongPort: .orange
        case .notRunning, .notInstalled: .red
        }
    }
}

/// What the dot meant, and the one command that fixes it.
private struct HostStatusSheet: View {
    let host: Host
    @Environment(GatewayProbe.self) private var probe
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                let state = probe.state(for: host)
                Section {
                    LabeledContent("State", value: state.label)
                    Text(state.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(host.displayName)
                }
                if let fix = state.fix {
                    Section {
                        // Selectable so it can be copied onto the host without
                        // retyping, which is the whole point of showing it.
                        Text(fix)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    } header: {
                        Text("Fix")
                    } footer: {
                        Text("Run this on \(host.target).")
                    }
                }
                Section {
                    Button("Check again") {
                        Task { await probe.probe(host) }
                    }
                    LabeledContent("Port", value: String(host.gatewayPort))
                }
            }
            .navigationTitle("Gateway")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    NavigationStack { HostsView() }
        .environment(HostStore())
        .environment(ThemeStore())
}