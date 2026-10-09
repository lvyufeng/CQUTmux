import SwiftUI

/// Recently dictated text, newest first, each entry re-sendable or copyable.
struct TranscriptionHistoryView: View {
    @Environment(TranscriptionHistory.self) private var history

    /// Sends an entry to the session that opened this screen.
    ///
    /// A closure rather than a terminal reference: the sheet has no business
    /// knowing how a session is reached, and the caller already has one.
    var onSend: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if history.entries.isEmpty {
                ContentUnavailableView(
                    "Nothing dictated yet",
                    systemImage: "waveform",
                    description: Text("Dictated lines appear here so you can send "
                                      + "them again or edit them before sending.")
                )
            } else {
                Section {
                    ForEach(history.entries) { entry in
                        row(entry)
                    }
                    .onDelete { offsets in
                        for index in offsets { history.remove(history.entries[index]) }
                    }
                } footer: {
                    Text("Only dictated text is kept — never what you type or paste, "
                         + "so passwords typed at a prompt do not end up here. "
                         + "The last \(TranscriptionHistory.limit) are stored on this device.")
                }
            }
        }
        .navigationTitle("Dictation History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !history.entries.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear", role: .destructive) { history.clear() }
                }
            }
        }
    }

    private func row(_ entry: TranscriptionHistory.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.text)
                .lineLimit(3)
            HStack(spacing: 12) {
                // Relative rather than absolute: the question being asked of a
                // dictation is "was this the one from a minute ago", not which
                // calendar day it was.
                Text(entry.at, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    // Copy rather than send, for the case the text is wanted in
                    // another app entirely.
                    UIPasteboard.general.string = entry.text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .font(.caption)
                Button {
                    onSend(entry.text)
                    dismiss()
                } label: {
                    Label("Send", systemImage: "arrow.up")
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}