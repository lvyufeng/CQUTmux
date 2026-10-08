import SwiftUI

/// tmux session/window picker. Mirrors Moshi's session selector: list what is
/// running on the host, attach to a session, or jump straight to one of its
/// windows.
///
/// Discovery goes through the host gateway over the SSH tunnel, so it works
/// without a second shell. Attaching and jumping need a live terminal, so the
/// view is given a `send` closure that types into the current session.
struct SessionPickerView: View {
    let client: HookClient
    /// Sends an attach or a window jump to the terminal.
    let send: (MuxAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var board: SessionBoard?
    @State private var error: String?
    @State private var loading = true

    /// A multiplexer command, tagged with its mux so the terminal knows which
    /// client to drive.
    enum MuxAction {
        case attach(mux: String, name: String)
        case window(mux: String, session: String, selector: String)
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Looking for tmux sessions…")
                } else if let error {
                    ContentUnavailableView {
                        Label("Can't reach tmux", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    }
                } else if let board, !board.available {
                    ContentUnavailableView {
                        Label("tmux not installed", systemImage: "terminal")
                    } description: {
                        Text(board.error ?? "Install tmux on the host to use sessions.")
                    }
                } else if let sessions = board?.sessions, sessions.isEmpty {
                    ContentUnavailableView {
                        Label("No sessions", systemImage: "rectangle.stack.badge.minus")
                    } description: {
                        Text("Start tmux on the host and its sessions will appear here.")
                    }
                } else if let sessions = board?.sessions {
                    List {
                        ForEach(sessions) { session in
                            Section {
                                Button {
                                    send(.attach(mux: session.mux, name: session.name))
                                    dismiss()
                                } label: {
                                    Label("Attach", systemImage: "rectangle.connected.to.line.below")
                                }
                                ForEach(session.windowList) { window in
                                    Button {
                                        send(.window(mux: session.mux, session: session.name, selector: window.selector))
                                        dismiss()
                                    } label: {
                                        HStack {
                                            Text(window.label)
                                                .font(.system(.body, design: .monospaced))
                                            Spacer()
                                            if window.panes > 1 {
                                                Text("\(window.panes) panes")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            if window.active {
                                                Image(systemName: "checkmark")
                                                    .font(.caption.weight(.bold))
                                                    .foregroundStyle(Theme.accent)
                                            }
                                        }
                                    }
                                    .foregroundStyle(.primary)
                                }
                            } header: {
                                HStack {
                                    Text(session.name)
                                    Text(session.mux)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if let status = session.status, status != "unknown" {
                                        Text(status)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(status == "blocked" ? .orange : Theme.accent)
                                    }
                                    Spacer()
                                    if session.attached {
                                        Text("attached")
                                            .font(.caption2)
                                            .foregroundStyle(Theme.accent)
                                    }
                                    Text("\(session.windows)w")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
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

    private func load() async {
        loading = true
        defer { loading = false }
        // The SSH tunnel takes a moment to come up; requesting before the
        // forwarded socket exists fails with -1009. Wait for the client to
        // report connected, the same way the code panel does.
        for _ in 0..<40 {
            switch client.state {
            case .connected:
                await fetch()
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

    private func fetch() async {
        do {
            board = try await client.sessions()
            error = nil
        } catch {
            board = nil
            self.error = "\(error)"
        }
    }
}