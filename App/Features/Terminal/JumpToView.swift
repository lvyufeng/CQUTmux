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
    @Environment(ThemeStore.self) private var themes
    let client: HookClient
    /// Called after a successful jump. The host focuses the pane; the app does
    /// not type anything, so the only thing left to do is get out of the way.
    let onJump: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tree: HerdrTree?
    @State private var error: String?
    @State private var loading = true
    @State private var jumping: String?
    /// Remembered across launches. The layout is not a per-session choice —
    /// someone who wants mission control wants it every time, and being reset
    /// to the list on every jump is the sort of thing that gets a screen
    /// abandoned.
    @AppStorage("cqutmux.jumpto.layout") private var layout: Layout = .list
    /// Workspaces whose accordion section is open. A set rather than one id:
    /// comparing two workspaces' agents is a normal thing to want, and forcing
    /// one closed to open another makes it impossible.
    @State private var expanded: Set<String> = []

    /// How the tree is shown. The three are for different questions: `list` for
    /// "which pane did I leave that in", `accordion` for a long tree where you
    /// want to see the shape, and `grid` for the moment the tree is beside the
    /// point and you just want the blocked agent.
    enum Layout: String, CaseIterable, Identifiable {
        case list = "List"
        case accordion = "Accordion"
        case grid = "Grid"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .list: "list.bullet"
            case .accordion: "list.bullet.indent"
            case .grid: "square.grid.2x2"
            }
        }
    }

    /// Panes whose agent is waiting on the user. Herdr reports this as a
    /// `blocked` status, which is the state the whole screen exists to surface
    /// — it is the one where nothing happens until someone looks.
    private var waitingCount: Int {
        let panes: [HerdrTree.Pane] = tree?.agents ?? []
        return panes.filter { $0.status == "blocked" }.count
    }

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
                    switch layout {
                    case .list: list(tree)
                    case .accordion: accordion(tree)
                    case .grid: grid(tree)
                    }
                }
            }
            .navigationTitle("Jump To")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                // The count sits above the tree rather than in the title,
                // because it is the reason to be on this screen at all and a
                // title is the first thing truncated on a phone.
                if !loading, error == nil, let tree, tree.installed, waitingCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass")
                        Text("\(waitingCount) waiting")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Button {
                            layout = .grid
                        } label: {
                            Text("Show")
                                .font(.subheadline)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.orange.opacity(0.15))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Layout", selection: $layout) {
                            ForEach(Layout.allCases) { option in
                                Label(option.rawValue, systemImage: option.symbol).tag(option)
                            }
                        }
                        .pickerStyle(.inline)
                        Divider()
                        Button {
                            Task { await load() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Label("Layout", systemImage: layout.symbol)
                    }
                }
            }
            .task {
                #if DEBUG
                // The layout lives behind a menu, and a script cannot open a
                // menu — so a run names the layout and the sheet starts in it,
                // which is the same state a tap would produce.
                if let raw = ProcessInfo.processInfo.environment["CQUT_DEV_JUMPTO_LAYOUT"],
                   let requested = Layout(rawValue: raw.capitalized) {
                    layout = requested
                }
                // Accordion sections start closed, so a run that wants a pane
                // list on screen with no way to tap a header opens them all.
                if ProcessInfo.processInfo.environment["CQUT_DEV_JUMPTO_EXPAND"] == "1" {
                    await load()
                    expanded = Set((tree?.workspaces ?? []).map(\.id))
                    return
                }
                #endif
                await load()
            }
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
                                .foregroundStyle(workspace.status == "blocked" ? .orange : themes.current.accentColor)
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

    /// Millisecond-free second line for a workspace header: herdr reports a status
    /// per workspace, and "blocked" is the one worth colouring.
    private func statusColor(_ status: String) -> Color {
        status == "blocked" ? .orange : themes.current.accentColor
    }

    /// One workspace open at a time, the rest collapsed to a summary row.
    ///
    /// Herdr on a real machine has more workspaces than fit on a phone screen,
    /// and a flat list makes the pane you want a scroll rather than a glance.
    /// The header keeps the counts so a collapsed workspace still says what is
    /// inside it — a fold that hides the reason to open it is worse than no
    /// fold.
    @ViewBuilder
    private func accordion(_ tree: HerdrTree) -> some View {
        List {
            ForEach(tree.workspaces) { workspace in
                let isOpen = expanded.contains(workspace.id)
                Section {
                    if isOpen {
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
                    }
                } header: {
                    Button {
                        if isOpen { expanded.remove(workspace.id) } else { expanded.insert(workspace.id) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                                .font(.caption2.weight(.bold))
                            Text(workspace.label)
                                .foregroundStyle(.primary)
                            if workspace.status != "unknown" {
                                Text(workspace.status)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(statusColor(workspace.status))
                            }
                            Spacer()
                            Text("\(workspace.tabCount) tabs · \(workspace.paneCount) panes")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .textCase(nil)
                }
            }
        }
    }

    /// Mission-control cards: one per workspace, its panes as chips.
    ///
    /// The chips are the panes, so the whole screen is one tap. This is the
    /// layout for "an agent is blocked somewhere, get me there" rather than for
    /// reading the tree, which is why a blocked panel sorts first and carries
    /// the count on it.
    @ViewBuilder
    private func grid(_ tree: HerdrTree) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(tree.workspaces) { workspace in
                    card(workspace, tree: tree)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func card(_ workspace: HerdrTree.Workspace, tree: HerdrTree) -> some View {
        let panes = tree.tabs(in: workspace).flatMap(\.panes)
        let blocked = panes.filter { $0.status == "blocked" }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(workspace.label)
                    .font(.headline)
                    .lineLimit(1)
                if workspace.focused {
                    Image(systemName: "scope")
                        .font(.caption)
                        .foregroundStyle(themes.current.accentColor)
                }
                Spacer()
                if blocked > 0 {
                    Text("\(blocked) waiting")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }

            if panes.isEmpty {
                Text("No panes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Wrapping chips. `LazyVGrid` inside the card would fight the
                // adaptive outer grid for width, so the flow is done by hand:
                // each pane is a fixed-width chip and `FlowLayout`-style
                // wrapping is not available before iOS 26, so this is a
                // horizontal scroll instead — which also keeps a wide workspace
                // from making the card taller than the screen.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(panes) { pane in
                            Button {
                                jump(to: pane)
                            } label: {
                                paneChip(pane, focused: tree.focusedPaneId == pane.paneId)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func paneChip(_ pane: HerdrTree.Pane, focused: Bool) -> some View {
        HStack(spacing: 5) {
            if jumping == pane.paneId {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: pane.agent.isEmpty ? "terminal" : "cpu")
                    .font(.caption)
                    .foregroundStyle(color(for: pane.status))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(pane.displayLabel)
                    .font(.caption)
                    .lineLimit(1)
                if !pane.agent.isEmpty {
                    Text(pane.agent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if focused {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(themes.current.accentColor)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(pane.status == "blocked" ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.12))
        )
    }

    @ViewBuilder
    private func row(_ pane: HerdrTree.Pane, tree: HerdrTree) -> some View {
        HStack(spacing: 10) {
            VStack(spacing: 3) {
                Image(systemName: pane.agent.isEmpty ? "terminal" : "cpu")
                    .foregroundStyle(color(for: pane.status))
                // The dot is separate from the tinted icon on purpose: the icon
                // says *what* runs here, the dot says whether it needs you, and
                // folding them into one glyph means a grey agent and a working
                // one differ only by hue — which is the distinction the screen
                // exists to make.
                Circle()
                    .fill(color(for: pane.status))
                    .frame(width: 6, height: 6)
            }
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
                    .foregroundStyle(themes.current.accentColor)
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
        case "working": themes.current.accentColor
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