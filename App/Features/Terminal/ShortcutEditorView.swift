import SwiftUI

/// Adds and edits the keys on the terminal's accessory bar.
///
/// The shorthand is the whole interface — no modifier matrix to tap through —
/// because the strings people already know from their terminal config are
/// faster to type than any picker, and the parser gives a real error when they
/// get it wrong. The live preview is there so the error arrives before saving
/// rather than as a key that quietly does nothing.
struct ShortcutEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: ShortcutStore

    @State private var draft = ""
    @State private var editing: CustomShortcut?

    /// Which syntax examples to show. Kept short: this is a reference, not
    /// documentation, and the footer carries the rest in one line.
    private static let examples = ["C-c", "C-b, T", "M-x", "S-Tab", "text:/clear"]

    var body: some View {
        List {
            Section("Custom shortcuts") {
                if store.shortcuts.isEmpty {
                    Text("No custom keys yet. Add one below — it appears on the keyboard bar above the terminal.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.shortcuts, id: \.id) { shortcut in
                    Button { editing = shortcut } label: { row(shortcut) }
                        .buttonStyle(.plain)
                }
                // Deletion is a swipe on the row, matching every other list here.
                .onDelete { offsets in
                    offsets.map { store.shortcuts[$0] }.forEach(store.remove)
                }
            }

            Section {
                HStack {
                    TextField("C-b, T", text: $draft)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Add a key")
            } footer: {
                Text("Modifiers: C- / Ctrl+, M- / Opt- / Alt+, S- / Shift+. Named keys: Tab, Enter, Esc, Space, BSpace, arrows, Home, End, PageUp, PageDown, F1–F12. Commas or spaces separate keystrokes, `,,` is a literal comma, and `text:…` sends the rest verbatim followed by Return.")
                    .font(.caption)
            }

            Section("Examples") {
                ForEach(Self.examples, id: \.self) { example in
                    Button(example) { draft = example }
                        .font(.system(.body, design: .monospaced))
                }
            }

            Section {
                Button("Remove all custom keys", role: .destructive) {
                    store.resetAll()
                }
                .disabled(store.shortcuts.isEmpty)
            } footer: {
                Text("The counterpart to \"Reset all gestures\": that screen clears "
                     + "the gestures, this one clears the keys, and between them "
                     + "nothing a user configured is left behind.")
                    .font(.caption)
            }
        }
        .navigationTitle("Shortcuts")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(item: $editing) { shortcut in
            NavigationStack {
                EditShortcutView(shortcut: shortcut) { updated in
                    store.update(updated)
                }
            }
        }
    }

    /// One row. Split out of the `ForEach` because the whole thing inline was
    /// more than the type checker would take in reasonable time.
    private func row(_ shortcut: CustomShortcut) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(shortcut.label)
                    .font(.system(.body, design: .monospaced))
                Text(shortcut.text)
                    .font(.caption2)
                    .foregroundStyle(shortcut.problem == nil ? Color.secondary : Color.orange)
            }
            Spacer()
            if shortcut.problem != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
            }
        }
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.add(text)
        draft = ""
    }
}

/// Editing one existing shortcut, including a display name for when the raw
/// text is unreadable as a button label.
private struct EditShortcutView: View {
    @State var shortcut: CustomShortcut
    var onSave: (CustomShortcut) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Keys") {
                TextField("C-b, T", text: $shortcut.text)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Label (optional)", text: $shortcut.displayName)
            }

            Section("Preview") {
                Preview(shortcut: shortcut)
            }
        }
        .navigationTitle("Edit Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(shortcut)
                    dismiss()
                }
            }
        }
    }

    /// Shows the exact bytes, which is the honest answer to "did it parse the
    /// way I meant" — the label alone cannot distinguish Ctrl+B then 1 from
    /// something else that reads the same.
    private struct Preview: View {
        let shortcut: CustomShortcut

        var body: some View {
            if let problem = shortcut.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else if let parsed = shortcut.parsed {
                VStack(alignment: .leading, spacing: 6) {
                    Text(parsed.label)
                        .font(.system(.body, design: .monospaced))
                    Text(parsed.steps.map { $0.bytes.map(byteName).joined(separator: " ") }
                        .joined(separator: "  ·  "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if parsed.autoEnter {
                        Text("Followed by Return")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        private func byteName(_ byte: UInt8) -> String {
            switch byte {
            case 0x1B: return "ESC"
            case 0x0D: return "CR"
            case 0x20...0x7E: return String(UnicodeScalar(byte))
            default: return String(format: "0x%02X", byte)
            }
        }
    }
}