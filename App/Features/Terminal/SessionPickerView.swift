import SwiftUI

/// tmux session/window picker. Mirrors Moshi's session selector: list what is
/// running on the host, attach to a session, or jump straight to one of its
/// windows.
///
/// A second tab returns to a folder: the last session used on this host, the
/// directories browsed here before, and the folders the host's own agents have
/// been working in. A folder opens a shell in it rather than attaching to a
/// session, so the view's closure is told which of the two a tap means.
///
/// Discovery goes through the host gateway over the SSH tunnel, so it works
/// without a second shell. Attaching, jumping and `cd` all need a live
/// terminal, so the view is given a closure that types into the current
/// session.
struct SessionPickerView: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(SessionLayout.self) private var layout
    let client: HookClient
    /// The host whose recent folders and saved sessions the Recent tab offers.
    /// Optional so the picker still works when it is presented without one.
    var host: Host? = nil
    /// Sends an attach, a window jump, or a directory to open to the terminal.
    /// Named for the action rather than the transport: a directory is typed
    /// into the session, not routed through the mux.
    let act: (PickerAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var board: SessionBoard?
    @State private var error: String?
    @State private var loading = true
    @State private var tab: Tab = .sessions
    /// Recently visited directories, from this app's own history.
    @State private var recents = RecentDirectoryStore()
    /// Directories the host's agents have been working in, discovered from
    /// their session logs. Fetched when the Recent tab is first shown.
    @State private var discovered: RecentDirectoryBoard?
    @State private var loadingDiscovered = false
    /// The last session this app attached to on the host, offered first.
    @State private var lastSessions = LastSessionStore()

    /// Which tab the picker is on.
    ///
    /// Sessions first: the live sessions are what a picker is opened for, and
    /// Recent is the way back to a folder rather than the main event.
    enum Tab: String, CaseIterable, Identifiable {
        case sessions, recent
        var id: String { rawValue }
        var title: String { self == .sessions ? "Sessions" : "Recent" }
    }

    /// What a tap asks the terminal to do. A session attach and a directory
    /// open look the same to this view — both are "put me here" — but they are
    /// different commands, so the caller is told which.
    enum PickerAction {
        case mux(MuxAction)
        case openDirectory(String)
    }

    /// A multiplexer command, tagged with its mux so the terminal knows which
    /// client to drive.
    enum MuxAction {
        case attach(mux: String, name: String)
        case window(mux: String, session: String, selector: String)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Above the content and always visible: switching tabs is how
                // the two halves are reached, and a picker hidden behind a
                // scroll would make the Recent tab look like it is not there.
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                content
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
        .task {
            #if DEBUG
            // A UI run cannot tap the segmented control, so a screenshot of the
            // Recent tab has to be reachable from launch. The picker itself is
            // opened by `CQUT_DEV_SHEET=sessions`.
            if ProcessInfo.processInfo.environment["CQUT_DEV_SESSION_TAB"] == "recent" {
                tab = .recent
            }
            #endif
            await load()
        }
        .task(id: tab) {
            // Fetched lazily: a picker opened to attach to a known session
            // should not pay for a host round trip it will not look at.
            guard tab == .recent else { return }
            await loadDiscovered()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .sessions:
            sessionsContent
        case .recent:
            recentList
        }
    }

    @ViewBuilder
    private var sessionsContent: some View {
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
    }

    /// The Recent tab: the way back into a folder, and into the session that
    /// was last used.
    ///
    /// What to show is decided in `RecentPicker`, not here, so the checks drive
    /// the same rule the screen does — in particular the difference between a
    /// host asked not to look and a host that looked and found nothing.
    @ViewBuilder
    private var recentList: some View {
        if let host {
            let sections = RecentPicker.sections(
                last: lastSessions.last(for: host),
                visited: recents.recent(for: host),
                discovered: discovered
            )
            if sections.isEmpty {
                if loadingDiscovered {
                    ProgressView()
                } else {
                    ContentUnavailableView {
                        Label("Nothing recent", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("Attach to a session or browse a folder on \(host.displayName) and it will show up here.")
                    }
                }
            } else {
                // Indexed rather than keyed by the section: a host has at most
                // one of each kind, and the order is what `RecentPicker` fixed.
                List {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        sectionView(section, host: host)
                    }
                }
            }
        } else {
            ContentUnavailableView {
                Label("No host", systemImage: "server.rack")
            } description: {
                Text("Recent folders are kept per host.")
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: RecentPicker.Section, host: Host) -> some View {
        switch section {
        case .lastSession(let last):
            Section("Last session") {
                Button {
                    act(.mux(.attach(mux: last.mux, name: last.name)))
                    dismiss()
                } label: {
                    Label("Attach to \(last.name)", systemImage: "arrow.uturn.backward")
                }
                // Only when a window was recorded: offering a jump to a window
                // nobody was in would be inventing a place.
                if let window = last.window, !window.isEmpty {
                    Button {
                        act(.mux(.window(mux: last.mux, session: last.name, selector: window)))
                        dismiss()
                    } label: {
                        Label("Window \(window) in \(last.name)", systemImage: "rectangle.on.rectangle")
                    }
                }
            }

        case .visited(let paths):
            Section {
                ForEach(paths, id: \.self) { path in
                    Button {
                        act(.openDirectory(path))
                        dismiss()
                    } label: {
                        Label(path, systemImage: "clock.arrow.circlepath")
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack {
                    Text("Recent folders")
                    Spacer()
                    Button("Clear") { recents.clear(for: host) }
                        .font(.caption)
                        .textCase(nil)
                }
            } footer: {
                Text("Folders you browsed in the Code tab. Opening one starts a shell there on \(host.displayName).")
            }

        case .agentFolders(let entries):
            Section {
                ForEach(entries) { entry in
                    Button {
                        act(.openDirectory(entry.path))
                        dismiss()
                    } label: {
                        discoveredRow(entry)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Agent history")
            } footer: {
                Text("Read from the agents' own session logs on \(host.displayName). A path marked with a question mark was reconstructed from a project's folder name, which loses the difference between a dash and a folder separator.")
            }

        case .discoveryOff:
            // Turned off is not the same as empty, and saying which it is is
            // the difference between "nothing to show" and "you asked me not to
            // look".
            Section {
                Label("Discovery is off", systemImage: "eye.slash")
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Turn it back on with `cqutmux set always-on-discovery on`.")
            }
        }
    }

    private func discoveredRow(_ entry: RecentDirectoryBoard.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.agentSymbol)
                .foregroundStyle(themes.current.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(entry.folderName)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                    if entry.inferred {
                        Image(systemName: "questionmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text("\(entry.agentLabel) · \(entry.parentPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
        }
    }

    /// Fetches the host's discovered directories.
    ///
    /// Failure is swallowed, like the Code page's copy: this is one section of
    /// a screen whose job is to attach to a session, and an error banner over a
    /// working list would make an optional extra look like the feature is
    /// broken.
    private func loadDiscovered() async {
        guard discovered == nil else { return }
        loadingDiscovered = true
        defer { loadingDiscovered = false }
        discovered = try? await client.recentDirectories()
    }

    /// The default: one row per window, grouped under its session.
    @ViewBuilder
    private func list(_ sessions: [SessionBoard.Session]) -> some View {
        List {
            ForEach(sessions) { session in
                            Section {
                                Button {
                                    act(.mux(.attach(mux: session.mux, name: session.name)))
                                    dismiss()
                                } label: {
                                    Label("Attach", systemImage: "rectangle.connected.to.line.below")
                                }
                                ForEach(session.windowList) { window in
                                    Button {
                                        act(.mux(.window(mux: session.mux, session: session.name, selector: window.selector)))
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
                act(.mux(.attach(mux: session.mux, name: session.name)))
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
                        act(.mux(.window(mux: session.mux, session: session.name, selector: window.selector)))
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