import SwiftUI

struct HostsView: View {
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
            ConnectFlowView(host: host)
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
    let host: Host

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName).font(.body.weight(.medium))
                Text("\(host.target):\(host.port) · \(host.transport.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct TerminalPlaceholderView: View {
    let host: Host

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
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
    NavigationStack { HostsView() }.environment(HostStore())
}