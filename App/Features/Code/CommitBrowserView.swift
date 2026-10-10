import SwiftUI

/// The repository as it was at one commit.
///
/// Reached from the History tab, where a commit row was previously inert. The
/// tree is the commit's own — not the working tree — so a file that has since
/// been deleted is still here, in the state that commit left it, and a file
/// added afterwards is absent.
struct CommitBrowserView: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(TerminalFontStore.self) private var fonts

    let root: String
    let target: BrowseTarget
    let client: HookClient

    @Environment(\.dismiss) private var dismiss
    @State private var dir = ""
    @State private var listing: RevisionListing?
    @State private var openFile: RevisionFile?
    @State private var error: String?
    /// Distinct from `listing == nil`: a fetch in flight and a directory that
    /// really is empty both draw as an empty list, and only one is worth a
    /// spinner.
    @State private var loading = true

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView {
                    Label("Can't open this commit", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else {
                List {
                    Section {
                        ForEach(Array(RevisionPath.breadcrumbs(of: dir).enumerated()), id: \.offset) { _, crumb in
                            Button(crumb.name) { move(to: crumb.path) }
                        }
                        Button {
                            move(to: "")
                        } label: {
                            Label("Root of this commit", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(dir.isEmpty)
                    } header: {
                        Text("\(RevisionPath.short(target.rev))  \(target.subject)")
                            .textCase(nil)
                            .font(.caption)
                            .lineLimit(2)
                    }

                    Section {
                        ForEach(listing?.entries ?? []) { entry in
                            row(entry)
                        }
                    } footer: {
                        if let entries = listing?.entries, entries.isEmpty, !loading {
                            // Reached only when a listing came back with nothing
                            // and no error, which is worth saying rather than
                            // drawing as a blank pane.
                            Text("Nothing here at this commit.")
                        }
                    }
                }
                .overlay { if loading && listing == nil { ProgressView() } }
            }
        }
        .navigationTitle(dir.isEmpty ? RevisionPath.short(target.rev) : dir)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .task { await load() }
        .sheet(item: $openFile) { file in
            NavigationStack {
                FileView(file: FileContents(path: file.file, size: file.size, content: file.content),
                             font: fonts.codeFont(), spacing: fonts.lineSpacing)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { openFile = nil }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: TreeEntry) -> some View {
        if entry.submodule {
            // Shown but not openable: the contents live in another repository,
            // so listing them here would come back empty and read as a bug.
            HStack {
                Label(entry.name, systemImage: "shippingbox")
                Spacer()
                Text("submodule").font(.caption2).foregroundStyle(.secondary)
            }
        } else if entry.dir {
            Button {
                move(to: RevisionPath.child(entry.name, of: dir))
            } label: {
                Label(entry.name, systemImage: "folder")
                    .foregroundStyle(themes.current.accentColor)
            }
        } else {
            Button {
                Task { await open(RevisionPath.child(entry.name, of: dir)) }
            } label: {
                Label(entry.name, systemImage: "doc.text")
            }
        }
    }

    private func move(to next: String) {
        dir = next
        listing = nil
        Task { await load() }
    }

    private func load() async {
        loading = true
        do {
            listing = try await client.tree(path: root, rev: target.rev, dir: dir)
            error = nil
        } catch {
            self.error = "\(error)"
        }
        loading = false
    }

    private func open(_ file: String) async {
        do {
            openFile = try await client.blob(path: root, rev: target.rev, file: file)
        } catch {
            self.error = "\(error)"
        }
    }
}
