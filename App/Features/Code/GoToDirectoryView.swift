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
    let onOpen: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

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
        }
    }

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func open() {
        guard !trimmed.isEmpty else { return }
        onOpen(trimmed)
        dismiss()
    }
}