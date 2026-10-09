import SwiftUI

/// What has been pasted to the host, so a screenshot does not have to be
/// uploaded again to be used again.
///
/// The paste directory is otherwise write-only: `POST /upload` returns a path
/// and nothing ever reads that directory back. Moshi's Files surface is the
/// same idea with a different transport — it returns a short expiring HTTPS URL
/// and keeps a list of what it has served.
///
/// This is the honest half of that. The list is here and the files are
/// re-usable; what this app does not have is the pastebin half — a public HTTPS
/// URL it can hand to `gh issue create`. Presenting a host path as if it were
/// such a URL would be worse than not having it, so the screen says which one
/// it is and the footer explains why the paths are only useful to an agent on
/// the same machine.
struct UploadsView: View {
    @Environment(AgentConnection.self) private var connection
    @Environment(HostStore.self) private var hosts

    @State private var uploads: [UploadBoard.Upload] = []
    @State private var loading = true
    @State private var problem: String?
    /// Brief confirmation after a copy, keyed by name so only the tapped row
    /// says anything.
    @State private var copied: String?

    var body: some View {
        List {
            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            if uploads.isEmpty && !loading {
                Section {
                    ContentUnavailableView {
                        Label("Nothing pasted yet", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text("Images you paste into the terminal land here, ready to reuse.")
                    }
                }
            } else {
                Section {
                    ForEach(uploads) { upload in
                        row(upload)
                    }
                } header: {
                    Text("\(uploads.count) upload\(uploads.count == 1 ? "" : "s")")
                } footer: {
                    Text("Paths on the host. An agent running there can read them "
                         + "directly; anything outside that machine needs the file "
                         + "moved to a service that serves URLs, which this app does "
                         + "not provide.")
                }
            }
        }
        .navigationTitle("Pasted files")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading && uploads.isEmpty { ProgressView() } }
        .refreshable { await load() }
        .task { await load() }
    }

    @ViewBuilder
    private func row(_ upload: UploadBoard.Upload) -> some View {
        Button {
            copy(upload)
        } label: {
            HStack(spacing: 12) {
                thumbnail(upload)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(upload.name))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(upload.sizeLabel)
                        if let date = upload.date {
                            Text(date, format: .relative(presentation: .named))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: copied == upload.name ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied == upload.name ? .green : .secondary)
            }
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button("Delete", role: .destructive) { delete(upload) }
        }
        .contextMenu {
            Button("Copy path", systemImage: "doc.on.doc") { copy(upload) }
            Button("Delete", systemImage: "trash", role: .destructive) { delete(upload) }
        }
    }

    /// Fetched from the host rather than cached across launches: the file lives
    /// there, and a thumbnail that outlives it would show something that is
    /// gone.
    @ViewBuilder
    private func thumbnail(_ upload: UploadBoard.Upload) -> some View {
        Group {
            if let data = thumbnails[upload.name], let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: upload.isImage ? "photo" : "doc")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: upload.name) { await loadThumbnail(upload) }
    }

    @State private var thumbnails: [String: Data] = [:]

    private func loadThumbnail(_ upload: UploadBoard.Upload) async {
        guard thumbnails[upload.name] == nil else { return }
        guard upload.isImage else { return }
        guard let client = connection.client else { return }
        if let data = try? await client.uploadData(name: upload.name) {
            thumbnails[upload.name] = data
        }
    }

    /// The name column is `millis-uuid-original.png`; the original is the part
    /// the user recognises.
    private func displayName(_ name: String) -> String {
        let parts = name.split(separator: "-")
        guard parts.count > 2 else { return name }
        return parts.dropFirst(2).joined(separator: "-")
    }

    private func load() async {
        guard let client = connection.client else {
            // Same self-healing the other tunnel-backed screens do: this one
            // must not be blank just because it was opened first.
            if let host = hosts.hosts.first {
                connection.connect(to: host)
            }
            problem = "Not connected to a host yet."
            loading = false
            return
        }
        do {
            uploads = try await client.uploads()
            problem = nil
        } catch {
            problem = "Could not read the paste directory: \(error.localizedDescription)"
        }
        loading = false
    }

    private func copy(_ upload: UploadBoard.Upload) {
        UIPasteboard.general.string = upload.path
        withAnimation { copied = upload.name }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { if copied == upload.name { copied = nil } }
        }
    }

    private func delete(_ upload: UploadBoard.Upload) {
        guard let client = connection.client else { return }
        Task {
            do {
                try await client.deleteUpload(name: upload.name)
                uploads.removeAll { $0.name == upload.name }
                thumbnails[upload.name] = nil
            } catch {
                problem = "Could not delete: \(error.localizedDescription)"
            }
        }
    }
}