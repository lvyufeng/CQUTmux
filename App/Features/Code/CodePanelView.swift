import SwiftUI

/// Files, Changes and History for the connected host — the code side of the
/// agent workflow. Everything is served by the host gateway over the SSH
/// tunnel, so source never leaves the machine.
struct CodePanelView: View {
    @Environment(AgentConnection.self) private var connection
    @Environment(HostStore.self) private var store

    @State private var mode: Mode = .changes
    @State private var listing: DirectoryListing?
    @State private var diff: DiffResult?
    @State private var error: String?
    @State private var openFile: FileContents?
    @State private var path = "."

    private enum Mode: String, CaseIterable { case files = "Files", changes = "Changes" }

    var body: some View {
        Group {
            if let client = connection.client {
                panel(client)
            } else {
                ContentUnavailableView {
                    Label("Not connected", systemImage: "server.rack")
                } description: {
                    Text("Pick a host on the Inbox tab to browse its files and diffs.")
                } actions: {
                    ForEach(store.hosts) { host in
                        Button(host.displayName) { connection.connect(to: host) }
                    }
                }
            }
        }
        .navigationTitle("Code")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func panel(_ client: HookClient) -> some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()

            if let error {
                ContentUnavailableView {
                    Label("Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else {
                switch mode {
                case .files: filesList(client)
                case .changes: changesList
                }
            }
        }
        .task { await load(client) }
        .sheet(item: $openFile) { (file: FileContents) in
            NavigationStack {
                FileView(file: file)
            }
        }
    }

    @ViewBuilder
    private func filesList(_ client: HookClient) -> some View {
        if let listing {
            List {
                if path != "." {
                    Button {
                        path = (path as NSString).deletingLastPathComponent
                        Task { await loadFiles(client) }
                    } label: {
                        Label("..", systemImage: "arrow.up")
                    }
                }
                ForEach(listing.entries) { entry in
                    Button {
                        let next = listing.path == "." ? entry.name : "\(listing.path)/\(entry.name)"
                        if entry.dir {
                            path = next
                            Task { await loadFiles(client) }
                        } else {
                            Task { openFile = try? await client.readFile(path: next) }
                        }
                    } label: {
                        Label(entry.name, systemImage: entry.dir ? "folder" : "doc.text")
                            .foregroundStyle(entry.dir ? Theme.accent : .primary)
                    }
                }
            }
        } else {
            ProgressView().padding()
        }
    }

    @ViewBuilder
    private var changesList: some View {
        if let diff {
            if !diff.isRepo {
                ContentUnavailableView {
                    Label("Not a git repository", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("This directory isn't under version control.")
                }
            } else if diff.files.isEmpty {
                ContentUnavailableView {
                    Label("Working tree clean", systemImage: "checkmark.circle")
                }
            } else {
                List {
                    Section("\(diff.files.count) changed") {
                        ForEach(diff.files) { file in
                            HStack {
                                Text(file.status)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.orange)
                                    .frame(width: 24, alignment: .leading)
                                Text(file.path).font(.system(.footnote, design: .monospaced))
                            }
                        }
                    }
                    Section("Diff") {
                        DiffText(diff.diff)
                    }
                }
            }
        } else {
            ProgressView().padding()
        }
    }

    private func load(_ client: HookClient) async {
        // The tunnel takes a moment to come up; loading immediately would fire
        // request() before the forwarded socket exists.
        for _ in 0..<40 {
            switch client.state {
            case .connected: return await loadNow(client)
            case .failed(let message):
                error = message
                return
            default:
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        error = "Timed out connecting to the host."
    }

    private func loadNow(_ client: HookClient) async {
        await loadFiles(client)
        await loadDiff(client)
    }

    private func loadFiles(_ client: HookClient) async {
        do {
            listing = try await client.listFiles(path: path)
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }

    private func loadDiff(_ client: HookClient) async {
        diff = try? await client.gitDiff(path: path)
    }
}

/// Renders a unified diff with the usual red/green tinting.
private struct DiffText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                Text(String(line).isEmpty ? " " : String(line))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(color(for: String(line)))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return .cyan }
        if line.hasPrefix("diff ") { return .secondary }
        return .primary
    }
}

private struct FileView: View {
    let file: FileContents

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(file.content)
                .font(.system(.caption, design: .monospaced))
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle((file.path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension FileContents: Identifiable {
    var id: String { path }
}