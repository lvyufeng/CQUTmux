import SwiftUI

/// tmux session/window picker. Mirrors Moshi's session selector: list what is
/// running on the host, attach to a session, or jump straight to one of its
/// windows.
///
/// Discovery goes through the host gateway over the SSH tunnel, so it works
/// without a second shell. Attaching and jumping need a live terminal, so the
/// view is given a `send` closure that types into the current session.
struct SessionPickerView: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(SessionLayout.self) private var layout
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
                    if layout.presents == "cards" {
                        cardList(sessions)
                    } else {
                        list(sessions)
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
        }
        .task { await load() }
    }

    /// The default: one row per window, grouped under its session.
    @ViewBuilder
    private func list(_ sessions: [SessionBoard.Session]) -> some View {
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
                                                    .foregroundStyle(themes.current.accentColor)
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
                                            .foregroundStyle(status == "blocked" ? .orange : themes.current.accentColor)
                                    }
                                    Spacer()
                                    if session.attached {
                                        Text("attached")
                                            .font(.caption2)
                                            .foregroundStyle(themes.current.accentColor)
                                    }
                                    Text("\(session.windows)w")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
        }
    }

    /// Sessions as cards — Moshi's denser alternative to the grouped list.
    ///
    /// A card summarises a session and expands to its windows, rather than
    /// showing every window up front. Worth offering because the two are for
    /// different jobs: the list is for finding a known window, the cards are
    /// for seeing what is running across many sessions at once, which is the
    /// case when several agents are working and most of them are idle.
    @ViewBuilder
    private func cardList(_ sessions: [SessionBoard.Session]) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(sessions) { session in
                    card(session)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func card(_ session: SessionBoard.Session) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(session.name)
                    .font(.system(.headline, design: .monospaced))
                Text(session.mux)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let status = session.status, status != "unknown" {
                    Text(status)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            (status == "blocked" ? Color.orange : themes.current.accentColor).opacity(0.2),
                            in: Capsule()
                        )
                        .foregroundStyle(status == "blocked" ? .orange : themes.current.accentColor)
                }
                Spacer()
                Text(session.attached ? "attached" : "\(session.windows)w")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button {
                send(.attach(mux: session.mux, name: session.name))
                dismiss()
            } label: {
                Label("Attach", systemImage: "rectangle.connected.to.line.below")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)

            // Wrapped rather than listed: the point of the card is to see the
            // session at a glance, and a scroll inside a scroll reads badly.
            FlowLayout(spacing: 6) {
                ForEach(session.windowList) { window in
                    Button {
                        send(.window(mux: session.mux, session: session.name, selector: window.selector))
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Text(window.label)
                                .font(.system(.caption, design: .monospaced))
                            if window.panes > 1 {
                                Text("\(window.panes)p")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if window.active {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.bold))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            window.active ? themes.current.accentColor.opacity(0.2) : Color.secondary.opacity(0.15),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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