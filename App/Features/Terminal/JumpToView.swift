import SwiftUI

/// Herdr's tree, as something to jump from: workspaces, the tabs inside them,
/// and the panes inside those.
///
/// This is a separate screen from the session picker rather than another level
/// of it, because the two answer different questions. The picker lists what you
/// can attach to; this lists where you can land inside what you have attached
/// to. Herdr is the only mux that can be addressed this way — tmux and zellij
/// have no way to name a pane — so the tab only appears where it works.
struct JumpToView: View {
    let client: HookClient
    /// Called after a successful jump. The host focuses the pane; the app does
    /// not type anything, so the only thing left to do is get out of the way.
    let onJump: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tree: HerdrTree?
    @State private var error: String?
    @State private var loading = true
    @State private var jumping: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Reading herdr…")
                } else if let error {
                    ContentUnavailableView {
                        Label("Can't reach herdr", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    }
                } else if let tree, !tree.installed {
                    ContentUnavailableView {
                        Label("herdr not installed", systemImage: "rectangle.3.group")
                    } description: {
                        Text("Jump To needs herdr on the host. Install it, then reopen this screen.")
                    }
                } else if let tree, tree.workspaces.isEmpty {
                    ContentUnavailableView {
                        Label("No workspaces", systemImage: "rectangle.3.group")
                    } description: {
                        Text("Start herdr on the host and its workspaces appear here.")
                    }
                } else if let tree {
                    list(tree)
                }
            }
            .navigationTitle("Jump To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await load() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private func list(_ tree: HerdrTree) -> some View {
        List {
            ForEach(tree.workspaces) { workspace in
                Section {
                    ForEach(tree.tabs(in: workspace)) { tab in
                        ForEach(tab.panes) { pane in
                            Button {
                                jump(to: pane)
                            } label: {
                                row(pane, tree: tree)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    HStack {
                        Text(workspace.label)
                        if workspace.status != "unknown" {
                            Text(workspace.status)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(workspace.status == "blocked" ? .orange : Theme.accent)
                        }
                        Spacer()
                        Text("\(workspace.tabCount) tabs · \(workspace.paneCount) panes")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ pane: HerdrTree.Pane, tree: HerdrTree) -> some View {
        HStack(spacing: 10) {
            Image(systemName: pane.agent.isEmpty ? "terminal" : "cpu")
                .foregroundStyle(color(for: pane.status))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pane.displayLabel).font(.body)
                    if !pane.agent.isEmpty {
                        Text(pane.agent)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                // The working directory is what tells two same-named agents
                // apart, so it is worth the second line when it is known.
                if !pane.cwd.isEmpty {
                    Text(pane.cwd)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer()
            if jumping == pane.paneId {
                ProgressView()
            } else if tree.focusedPaneId == pane.paneId {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accent)
            } else if pane.status != "unknown" {
                Text(pane.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func color(for status: String) -> Color {
        switch status {
        case "blocked": .orange
        case "working": Theme.accent
        case "idle": .secondary
        default: .secondary
        }
    }

    private func jump(to pane: HerdrTree.Pane) {
        jumping = pane.paneId
        Task {
            do {
                try await client.focusHerdrPane(pane.paneId)
                onJump()
                dismiss()
            } catch {
                self.error = "\(error)"
                jumping = nil
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        // The tunnel takes a moment; asking before it exists fails as if the
        // host were unreachable, which is the wrong thing to tell the user.
        for _ in 0..<40 {
            switch client.state {
            case .connected:
                do {
                    tree = try await client.herdrTree()
                    error = nil
                } catch {
                    tree = nil
                    self.error = "\(error)"
                }
                return
            case .failed(let message):
                error = message
                return
            default:
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        error = "Timed out connecting to the host."
    }
}