import SwiftUI

/// Files, Changes and History for the connected host — the code side of the
/// agent workflow. Everything is served by the host gateway over the SSH
/// tunnel, so source never leaves the machine.
struct CodePanelView: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(AgentConnection.self) private var connection
    @Environment(HostStore.self) private var store
    @Environment(AppSettings.self) private var app
    @Environment(TerminalFontStore.self) private var fonts

    @State private var mode: Mode = Self.initialMode
    @State private var listing: DirectoryListing?
    @State private var diff: DiffResult?
    @State private var log: LogResult?
    @State private var error: String?
    @State private var openFile: FileContents?
    /// The changed file whose diff is open, if any.
    @State private var openDiff: DiffResult.File?
    /// Where the user was last looking in the diff viewer, restored when they
    /// come back. Persisted because a review is not one sitting — you read a
    /// hunk, go look at the source, come back — and being dropped at the top of
    /// a thousand-line diff every time is the thing that makes a reviewer stop
    /// using the phone for it.
    @AppStorage("cqutmux.code.lastDiffFile") private var lastDiffFile = ""
    @State private var path = "."
    @State private var showPreview = false
    @State private var showSimulator = false
    @State private var showGoTo = false
    @State private var showUploads = false
    @State private var recents = RecentDirectoryStore()

    private enum Mode: String, CaseIterable { case files = "Files", changes = "Changes", history = "History", chat = "Chat" }

    /// The modes the segmented control offers.
    ///
    /// Files is droppable because it is the one mode that duplicates something
    /// the user already has elsewhere — a file tree on the host — while the
    /// diff, the transcript and the chat have nowhere else to live. The mode
    /// itself stays in the enum so a deep link or a debug variable that names it
    /// still resolves; only the button goes.
    private var modes: [Mode] {
        Mode.allCases.filter { $0 != .files || !app.hidesFiles }
    }

    private static var initialMode: Mode {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CQUT_DEV_MODE"] == "history" { return .history }
        if ProcessInfo.processInfo.environment["CQUT_DEV_MODE"] == "files" { return .files }
        if ProcessInfo.processInfo.environment["CQUT_DEV_MODE"] == "chat" { return .chat }
        #endif
        return .changes
    }

    private static var previewInitiallyOpen: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CQUT_DEV_SHEET"] == "preview"
        #else
        return false
        #endif
    }

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
        // With one host there is no choice to make, so the tab connects
        // instead of asking. With several it keeps the picker: guessing which
        // machine to browse would be worse than a tap.
        .task {
            if connection.client == nil, store.hosts.count == 1, let only = store.hosts.first {
                connection.connect(to: only)
            }
        }
        .toolbar {
            if connection.client != nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showGoTo = true
                        } label: {
                            Label("Go to directory", systemImage: "arrow.right.to.line")
                        }
                        Button {
                            showUploads = true
                        } label: {
                            Label("Pasted files", systemImage: "photo.on.rectangle.angled")
                        }
                        Button {
                            showPreview = true
                        } label: {
                            Label("Browser preview", systemImage: "safari")
                        }
                        Button {
                            showSimulator = true
                        } label: {
                            Label("Simulator preview", systemImage: "iphone.gen3")
                        }
                    } label: {
                        Label("Preview", systemImage: "play.rectangle")
                    }
                }
            }
        }
        .task {
            #if DEBUG
            // Recents cannot be built by tapping in a script, so a run can
            // seed a directory the same way the tap path would record it.
            if let seeded = ProcessInfo.processInfo.environment["CQUT_DEV_RECENT"] {
                for _ in 0..<40 where connection.host == nil {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                if let host = connection.host {
                    seeded.split(separator: ",").map(String.init).forEach {
                        recents.record($0, for: host)
                    }
                }
            }
            // Opened only once a host is known: the sheet is built around the
            // connected host, and presenting it before the connection lands
            // gives an empty sheet rather than an error.
            if ProcessInfo.processInfo.environment["CQUT_DEV_SHEET"] == "goto" {
                for _ in 0..<40 where connection.host == nil {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                showGoTo = connection.host != nil
            }
            #endif
        }
        .sheet(isPresented: $showGoTo) {
            if let host = connection.host {
                GoToDirectoryView(
                    host: host, current: path, recents: recents, client: connection.client
                ) { next in
                    path = next
                    recents.record(next, for: host)
                    Task { if let client = connection.client { await loadFiles(client) } }
                }
            }
        }
        .sheet(isPresented: $showPreview) {
            if let client = connection.client {
                PreviewView(client: client)
            }
        }
        .sheet(isPresented: $showSimulator) {
            if let client = connection.client {
                SimulatorPreviewView(client: client)
            }
        }
        .sheet(isPresented: $showUploads) {
            NavigationStack { UploadsView() }
        }
    }

    @ViewBuilder
    private func panel(_ client: HookClient) -> some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $mode) {
                ForEach(modes, id: \.self) { Text($0.rawValue).tag($0) }
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
                case .history: historyList
                // The transcript is read from the same project directory the Files
                // tab browses, so the two stay on the same session without a
                // second picker to keep in step.
                case .chat: ChatView(client: client, path: path)
                }
            }
        }
        .task {
            await load(client)
            #if DEBUG
            if Self.previewInitiallyOpen { showPreview = true }
            // Opens the per-file diff viewer on a named file, so a run can see
            // it without a tap the script cannot make.
            if let raw = ProcessInfo.processInfo.environment["CQUT_DEV_DIFF_FILE"], !raw.isEmpty,
               let listed = diff?.files.first(where: { $0.path == raw }) {
                lastDiffFile = listed.path
                openDiff = listed
            }
            if ProcessInfo.processInfo.environment["CQUT_DEV_SHEET"] == "simulator" { showSimulator = true }
            if ProcessInfo.processInfo.environment["CQUT_DEV_SHEET"] == "uploads" { showUploads = true }
            #endif
        }
        .sheet(item: $openFile) { (file: FileContents) in
            NavigationStack {
                FileView(file: file, font: fonts.codeFont(), spacing: fonts.lineSpacing)
            }
        }
        .sheet(item: $openDiff) { file in
            if let client = connection.client {
                NavigationStack {
                    FileDiffView(file: file, root: path, client: client, font: fonts.codeFont(), spacing: fonts.lineSpacing)
                }
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
                            // Recorded here as well as from "Go to": a
                            // directory reached by tapping is one the user is
                            // just as likely to want back.
                            if let host = connection.host { recents.record(next, for: host) }
                            Task { await loadFiles(client) }
                        } else {
                            Task { openFile = try? await client.readFile(path: next) }
                        }
                    } label: {
                        Label(entry.name, systemImage: entry.dir ? "folder" : "doc.text")
                            .foregroundStyle(entry.dir ? themes.current.accentColor : .primary)
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
                            Button {
                                lastDiffFile = file.path
                                openDiff = file
                            } label: {
                                HStack(spacing: 8) {
                                    Text(file.status)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.orange)
                                        .frame(width: 24, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(file.name).font(.system(.footnote, design: .monospaced))
                                        // Only shown when it says something the
                                        // name does not, so a flat directory
                                        // does not double every row's height.
                                        if !file.directory.isEmpty {
                                            Text(file.directory)
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.head)
                                        }
                                    }
                                    Spacer()
                                    if lastDiffFile == file.path {
                                        Image(systemName: "bookmark.fill")
                                            .font(.caption2)
                                            .foregroundStyle(themes.current.accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // The whole-tree diff stays under the list — it is how you
                    // see the shape of a change across files — but laid out as
                    // two columns so a modification reads as one change rather
                    // than as an unrelated deletion and insertion.
                    Section("All changes") {
                        SideBySideDiffView(
                            text: diff.diff, font: fonts.codeFont(), spacing: fonts.lineSpacing
                        )
                    }
                }
            }
        } else {
            ProgressView().padding()
        }
    }

    @ViewBuilder
    private var historyList: some View {
        if let log {
            if !log.isRepo {
                ContentUnavailableView {
                    Label("Not a git repository", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("This directory isn't under version control.")
                }
            } else if log.commits.isEmpty {
                ContentUnavailableView {
                    Label("No commits", systemImage: "clock.arrow.circlepath")
                }
            } else {
                List(log.commits) { commit in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(commit.subject)
                            .font(.subheadline)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            Text(commit.short)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(themes.current.accentColor)
                            Text(commit.author).font(.caption2).foregroundStyle(.secondary)
                            Text(relative(commit.dateValue)).font(.caption2).foregroundStyle(.secondary)
                        }
                        if !commit.refs.isEmpty {
                            Text(commit.refs.replacingOccurrences(of: "HEAD -> ", with: ""))
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } else {
            ProgressView().padding()
        }
    }

    private func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
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
        await loadLog(client)
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

    private func loadLog(_ client: HookClient) async {
        log = try? await client.gitLog(path: path)
    }
}

/// Renders a unified diff with the usual red/green tinting.
/// The diff as two columns: removed on the left, added on the right.
///
/// Phone-tuned rather than faithful: a phone cannot show two full columns of
/// source, so each side is capped in width and scrolls horizontally, and the
/// pairing is what carries the meaning. A hunk header is full width above its
/// rows — it is not content and has no side.
private struct SideBySideDiffView: View {
    let text: String
    var font: UIFont = .monospacedSystemFont(ofSize: 11, weight: .regular)
    var spacing: Double = 1

    var body: some View {
        let hunks = SideBySideDiff.hunks(in: text)
        if hunks.isEmpty {
            // A diff with no hunks — binary, mode change — has nothing to lay
            // out, and a bare empty box reads as a failed load.
            Text(text.isEmpty ? "No textual changes." : text)
                .font(Font(font))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(hunks.enumerated()), id: \.offset) { _, hunk in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(hunk.header)
                            .font(Font(font))
                            .foregroundStyle(.cyan)
                            .padding(.vertical, 1)
                        ForEach(Array(hunk.rows.enumerated()), id: \.offset) { _, row in
                            SideBySideRow(row: row, font: font, spacing: spacing)
                        }
                    }
                }
            }
        }
    }
}

/// One paired row: the old line on the left, the new line on the right.
///
/// The two sides share a divider so a modification reads across it. Each side
/// is half the width and scrolls horizontally on its own — a phone cannot fit
/// two columns of source, and wrapping a code line reads as two lines.
private struct SideBySideRow: View {
    let row: SideBySideDiff.Row
    var font: UIFont
    var spacing: Double

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            side(row.left, tint: row.kind == .removed || row.kind == .modified ? .red : nil)
            Rectangle()
                .fill(.secondary.opacity(0.25))
                .frame(width: 1)
            side(row.right, tint: row.kind == .added || row.kind == .modified ? .green : nil)
        }
    }

    @ViewBuilder
    private func side(_ line: SideBySideDiff.Line?, tint: Color?) -> some View {
        let marker = Self.marker(for: line?.kind)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                Text(marker)
                    .font(Font(font))
                    .foregroundStyle(tint ?? .secondary)
                Text(line?.text.isEmpty == false ? line!.text : " ")
                    .font(Font(font))
                    .foregroundStyle(tint ?? .primary)
                    .lineSpacing(spacing)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((tint ?? .clear).opacity(0.08))
    }

    /// The gutter marker per side, so a row says at a glance which side
    /// changed. A nil line is a gap and takes a blank gutter rather than a
    /// stray dash.
    private static func marker(for kind: SideBySideDiff.Line.Kind?) -> String {
        switch kind {
        case .removed: "-"
        case .added: "+"
        case .context: " "
        case nil: " "
        }
    }
}

private struct DiffText: View {
    let text: String
    /// The terminal's own font, so the code being reviewed is set in the same
    /// face as the code being written. A review that switches typeface is a
    /// review where column alignment stops lining up with the terminal beside
    /// it — and the user picked that font for a reason.
    var font: UIFont = .monospacedSystemFont(ofSize: 11, weight: .regular)
    var spacing: Double = 1

    init(_ text: String, font: UIFont = .monospacedSystemFont(ofSize: 11, weight: .regular), spacing: Double = 1) {
        self.text = text
        self.font = font
        self.spacing = spacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                Text(String(line).isEmpty ? " " : String(line))
                    .font(Font(font))
                    .lineSpacing(spacing)
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
    var font: UIFont = .monospacedSystemFont(ofSize: 11, weight: .regular)
    var spacing: Double = 1

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(file.content)
                .font(Font(font))
                .lineSpacing(spacing)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle((file.path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One changed file's hunks, with the position kept.
///
/// A separate view from `FileView` because the two scroll differently: a whole
/// file is read by scrolling to a line, while a diff is read by scrolling to a
/// *hunk*. Remembering where the reader was is the difference between coming
/// back to a review and re-finding your place in it.
private struct FileDiffView: View {
    let file: DiffResult.File
    let root: String
    let client: HookClient
    var font: UIFont = .monospacedSystemFont(ofSize: 11, weight: .regular)
    var spacing: Double = 1

    @Environment(\.dismiss) private var dismiss
    @State private var diff: DiffResult?
    @State private var error: String?
    /// The remembered top line, restored once the diff has arrived.
    @AppStorage("cqutmux.code.lastDiffLine") private var lastLine = 0
    /// Bumped to scroll the restored position back from the top button.
    @State private var scrollTarget = 0
    /// The top line currently on screen, which is what gets remembered.
    @State private var visibleRow: Int?

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView {
                    Label("Can't read the diff", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else if let diff {
                ScrollViewReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        VStack(alignment: .leading, spacing: 0) {
                            // Laid out side by side, one id per hunk. The
                            // remembered position is the hunk, which is the unit
                            // a diff is read by — a line id would have to change
                            // meaning now that a row holds two lines.
                            ForEach(Array(SideBySideDiff.hunks(in: diff.diff).enumerated()), id: \.offset) { index, hunk in
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(hunk.header)
                                        .font(Font(font))
                                        .foregroundStyle(.cyan)
                                        .padding(.vertical, 2)
                                    ForEach(Array(hunk.rows.enumerated()), id: \.offset) { _, row in
                                        SideBySideRow(row: row, font: font, spacing: spacing)
                                    }
                                }
                                .padding(.bottom, 8)
                                .id(index)
                            }
                        }
                        .padding()
                    }
                    // Restoring after layout: scrolling to an id before the
                    // rows exist does nothing, which is how a restored
                    // position silently resets to the top.
                    .onAppear {
                        scrollTarget = lastLine
                        guard lastLine > 0 else { return }
                        // After layout: scrolling to an id before the rows
                        // exist does nothing, which is how a restored position
                        // silently resets to the top.
                        DispatchQueue.main.async { proxy.scrollTo(lastLine, anchor: .top) }
                    }
                    // Where the reader stopped, recorded as they scroll. A
                    // plain `.onDisappear` would only fire on a clean dismissal,
                    // and a swipe-back can leave the sheet without it.
                    .scrollPosition(id: $visibleRow, anchor: .top)
                    .onChange(of: visibleRow) { _, row in
                        if let row { scrollTarget = row; lastLine = row }
                    }
                    .onChange(of: scrollTarget) { _, target in
                        if target == 0 { withAnimation { proxy.scrollTo(0, anchor: .top) } }
                    }
                    .overlay(alignment: .topTrailing) {
                        // A visible way back to the top, since a long diff's
                        // only affordance otherwise is a lot of dragging.
                        if scrollTarget > 0 {
                            Button {
                                scrollTarget = 0
                            } label: {
                                Image(systemName: "arrow.up.to.line")
                                    .padding(8)
                                    .background(.thinMaterial, in: Circle())
                            }
                            .padding(12)
                        }
                    }
                }
            } else {
                ProgressView().padding()
            }
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task {
            do {
                diff = try await client.gitDiff(path: root, file: file.path)
            } catch {
                self.error = "\(error)"
            }
        }
    }

}

/// The usual red/green tinting, in one place so the list and the file view
/// cannot drift apart about what a `@@` looks like.
private enum DiffPalette {
    static func color(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return .cyan }
        if line.hasPrefix("diff ") { return .secondary }
        return .primary
    }
}

extension FileContents: Identifiable {
    var id: String { path }
}