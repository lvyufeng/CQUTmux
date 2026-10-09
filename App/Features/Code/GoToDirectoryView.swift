import SwiftUI

/// Types a path, or picks one visited before.
///
/// Tapping down a deep tree is fine once and tedious every time after; this is
/// the way back to the one directory someone actually works in.
struct GoToDirectoryView: View {
    @Environment(ThemeStore.self) private var themes
    let host: Host
    let current: String
    let recents: RecentDirectoryStore
    /// The gateway connection, used to ask the host which directories its
    /// agents have been working in. Optional: the screen is reachable from the
    /// Code panel, which may be open without a tunnel, and a missing
    /// connection should cost the discovered list rather than the whole screen.
    var client: HookClient?
    let onOpen: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var discovered: RecentDirectoryBoard?
    @State private var loadingDiscovered = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("~/projects/app", text: $draft)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(open)
                        Button("Open", action: open)
                            .disabled(trimmed.isEmpty)
                    }
                } footer: {
                    Text("Paths are relative to the home directory on \(host.displayName).")
                        .font(.caption)
                }

                let list = recents.recent(for: host)
                if !list.isEmpty {
                    Section {
                        ForEach(list, id: \.self) { path in
                            Button {
                                onOpen(path)
                                dismiss()
                            } label: {
                                HStack {
                                    Label(path, systemImage: "clock.arrow.circlepath")
                                        .font(.system(.body, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                    Spacer()
                                    if path == current {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(themes.current.accentColor)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text("Recent")
                            Spacer()
                            Button("Clear") { recents.clear(for: host) }
                                .font(.caption)
                                .textCase(nil)
                        }
                    }
                }

                discoveredSection
            }
            .navigationTitle("Go to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                // Start from where the user is, so a small correction to the
                // current path beats typing the whole thing again.
                if draft.isEmpty, current != "." { draft = current }
            }
            .task {
                guard client != nil, discovered == nil else { return }
                await loadDiscovered()
            }
        }
    }

    /// Where the host's own agents have been working.
    ///
    /// A separate section from the visits this app recorded, because they are
    /// different claims: one is "you were here in this browser", the other is
    /// "an agent ran here on the host". Merging them would make a directory the
    /// user has never opened look like one they had.
    @ViewBuilder
    private var discoveredSection: some View {
        if let client {
            if let board = discovered, board.enabled {
                if !board.directories.isEmpty {
                    Section {
                        ForEach(board.directories) { entry in
                            Button {
                                onOpen(entry.path)
                                dismiss()
                            } label: {
                                row(entry)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Agent history")
                    } footer: {
                        Text(historyFooter)
                    }
                }
            } else if discovered?.enabled == false {
                // Turned off is not the same as empty, and saying which it is
                // is the difference between "nothing to show" and "you asked me
                // not to look".
                Section {
                    Label("Discovery is off", systemImage: "eye.slash")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text(discoveryOffFooter)
                }
            } else if loadingDiscovered {
                Section { ProgressView() }
            }
        }
    }

    private func row(_ entry: RecentDirectoryBoard.Entry) -> some View {
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
                HStack(spacing: 5) {
                    Text(entry.parentPath)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text("·")
                    Text(entry.agentLabel)
                    Text("·")
                    Text(relativeLabel(entry.at))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if entry.path == current {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(themes.current.accentColor)
            }
        }
    }

    /// The gateway sends milliseconds since the epoch, which `Text(_:format:)`
/// cannot take directly — it wants a `Date`, and `Date.RelativeFormatStyle`
/// would otherwise be handed a bare number and refuse to compile.
    private func relativeLabel(_ milliseconds: Double) -> String {
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        return date.formatted(.relative(presentation: .named))
    }

    /// Extracted from the view builder: several concatenated literals inside a
    /// `Text` in a `Section` footer is more than the type checker will do in one
    /// expression, and it reports that as "unable to type-check in reasonable
    /// time" rather than as the real complaint.
    private var historyFooter: String {
        "Read from the agents' own session logs on \(host.displayName). "
        + "A path marked with a question mark was reconstructed from a project's "
        + "folder name, which loses the difference between a dash and a folder "
        + "separator — the path may not exist, so it is shown as a guess."
    }

    private var discoveryOffFooter: String {
        "You turned discovery off on the host, so nothing was looked at. "
        + "Turn it back on with `cqutmux set always-on-discovery on`."
    }

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func open() {
        guard !trimmed.isEmpty else { return }
        onOpen(trimmed)
        dismiss()
    }

    /// Fetches the host's discovered directories.
    ///
    /// Failure is swallowed on purpose: this section is a convenience on a
    /// screen whose real job is typing a path, and an error banner over a
    /// working text field would make an optional extra look like the feature.
    /// The app-side "Recent" list above is unaffected either way.
    private func loadDiscovered() async {
        guard let client else { return }
        loadingDiscovered = true
        defer { loadingDiscovered = false }
        discovered = try? await client.recentDirectories()
    }
}