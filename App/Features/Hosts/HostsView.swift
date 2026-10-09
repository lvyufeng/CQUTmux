import SwiftUI

struct HostsView: View {
    @Environment(ThemeStore.self) private var themes
    /// A link that named a host or a session. Held by the shell rather than
    /// here because a link can arrive before this view exists.
    var pendingLink: DeepLink?

    @Environment(HostStore.self) private var store
    @State private var editing: Host?
    @State private var path: [Host] = []

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
                    Button("Add Host") { editing = Host() }
                        .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(store.hosts) { host in
                    NavigationLink(value: host) {
                        HostRow(host: host)
                    }
                }
                .onDelete { indexSet in
                    indexSet.map { store.hosts[$0] }.forEach(store.delete)
                }
            }
        }
        .navigationTitle("Terminal")
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
        .task {
            #if DEBUG
            if path.isEmpty,
               let target = store.hosts.first(where: { $0.hostname == ProcessInfo.processInfo.environment["CQUT_DEV_HOST"] }) {
                path = [target]
            }
            #endif
        }
    }
}

private struct HostRow: View {
    @Environment(ThemeStore.self) private var themes
    let host: Host

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
        }
    }
}

struct TerminalPlaceholderView: View {
    let host: Host
    @Environment(ThemeStore.self) private var themes

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 44))
                .foregroundStyle(themes.current.accentColor)
            Text(host.target)
                .font(.headline)
            Text("Terminal surface lands in Phase 1 (SSH + tmux + SwiftTerm).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .navigationTitle(host.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { HostsView() }
        .environment(HostStore())
        .environment(ThemeStore())
}