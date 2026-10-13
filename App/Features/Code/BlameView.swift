import SwiftUI

/// Who to ask for a blame, and what to ask them.
///
/// Built at the call site because only the caller knows which shape its file
/// path is in: the Files tab holds a path named from the gateway's root, the
/// commit browser a path relative to the directory it opened. One of them has
/// to be split and the other must not be, and guessing which here is the bug
/// this type exists to keep out.
struct BlameSource {
    let client: HookClient
    let request: BlameRequest
}

/// Who last touched each line of a file — the file viewer's second reading.
///
/// Pushed rather than presented: a blame is the same file under a different
/// light, and the back button returns to the code it explains. The rows are
/// derived in `BlameRow`, and every way the request can fail is worded in
/// `BlameFailure`, so this view decides only how they are laid out.
struct BlameView: View {
    let source: BlameSource
    var font: UIFont = .monospacedSystemFont(ofSize: 11, weight: .regular)
    var spacing: Double = 1

    /// One state rather than a `RevisionBlame?` beside a failure: "still
    /// loading", "loaded and empty" and "refused" all draw as a blank pane on
    /// their own, which is how a refusal came to look like a file with no
    /// lines.
    private enum Load {
        case loading
        case loaded([BlameRow])
        case failed(BlameFailure)
    }

    @State private var state: Load = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView().padding()
            case .failed(let reason):
                failureView(reason)
            case .loaded(let rows) where rows.isEmpty:
                // A zero-byte file is not a failure: git blames it, exits 0,
                // and has nothing to report. Said out loud, because the pane
                // for a failed blame used to be this one.
                ContentUnavailableView {
                    Label("Nothing to blame", systemImage: "doc")
                } description: {
                    Text("This file has no lines to attribute.")
                }
            case .loaded(let rows):
                table(rows)
            }
        }
        .navigationTitle((source.request.file as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    /// The rows, as one table.
    ///
    /// A single scroll for the whole table, not one per row: rows are read
    /// against each other — where one commit's run of lines ends — and rows
    /// that scroll on their own drift out of alignment with the line above.
    ///
    /// Eager rather than lazy: the host refuses a blame whose porcelain output
    /// is over its cap, so the table is bounded, and the diff viewer lays its
    /// own rows out the same way.
    private func table(_ rows: [BlameRow]) -> some View {
        let width = BlameRow.numberWidth(of: rows)
        return ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                header
                ForEach(rows, id: \.number) { row in
                    self.row(row, width: width)
                }
            }
            .padding()
        }
    }

    /// Which revision this blame is of. The viewer that pushed it showed the
    /// working tree or a commit, and an attribution that reads "just now"
    /// means something different in each.
    private var header: some View {
        Text(source.request.rev.isEmpty
             ? "Working tree"
             : "At \(RevisionPath.short(source.request.rev))")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
    }

    /// One line: who last touched it, then the line itself.
    ///
    /// The number is padded to the gutter's width inside the text rather than
    /// framed to a width measured here. The font is monospaced, so spaces and
    /// digits advance alike and the numbers line up; a frame sized from an
    /// estimated character width clips a number on a font wider than the
    /// estimate, and a clipped line number is a wrong one.
    private func row(_ row: BlameRow, width: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(row.attribution)
                .font(.caption2)
                // An uncommitted line is the one thing on this screen that is
                // not history yet, and the one thing worth spotting.
                .foregroundStyle(row.uncommitted ? Color.orange : Color.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%\(width)d", row.number))
                    .font(Font(font).monospacedDigit())
                    .foregroundStyle(.secondary)
                // Never wrapped: a code line broken across two reads as two
                // lines, and the gutter exists to say which line each one is.
                // The table scrolls sideways instead.
                Text(row.content.isEmpty ? " " : row.content)
                    .font(Font(font))
                    .fixedSize(horizontal: true, vertical: false)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, spacing)
    }

    @ViewBuilder
    private func failureView(_ reason: BlameFailure) -> some View {
        ContentUnavailableView {
            Label(reason.title, systemImage: reason.symbol)
        } description: {
            Text(reason.detail)
        } actions: {
            // Only a dropped connection is worth asking again: a 403 or a 404
            // is the host's answer about the repository, and asking the same
            // question gets the same answer. The tunnel is the part that comes
            // back.
            if reason == .connection {
                Button("Try again") { Task { await load() } }
            }
        }
    }

    private func load() async {
        state = .loading
        let request = source.request
        do {
            let blame = try await source.client.blame(
                path: request.path, rev: request.rev, file: request.file
            )
            state = .loaded(BlameRow.rows(of: blame))
        } catch HookClient.Failure.server(let status, let message) {
            // The one browsing call that throws with its status intact — the
            // others leave it to the decoder and lose it — so the 403 and the
            // 404s are told apart here instead of being flattened on arrival.
            state = .failed(BlameFailure.classify(status: status, message: message, rev: request.rev))
        } catch {
            // Everything else is the transport, or a reply this version cannot
            // read. Neither is an answer about the repository.
            state = .failed(.connection)
        }
    }
}