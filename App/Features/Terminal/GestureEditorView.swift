import SwiftUI

/// Binds the terminal's gestures to shortcuts.
///
/// Deliberately the same grammar and the same editor shape as the accessory
/// bar, because a gesture binding and a key binding are the same thing sent a
/// different way — two vocabularies for one idea is how a feature becomes two
/// half-learned ones. What each gesture does today is shown, so unbinding
/// something is not a guess about what it will fall back to.
struct GestureEditorView: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(ToolbarSettings.self) private var toolbar
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: GestureStore

    /// Which gesture is being edited, so the field and its error sit on the row
    /// they belong to rather than all of them sharing one.
    @State private var editing: TerminalGesture?
    @State private var draft = ""

    var body: some View {
        // Not named `toolbar`: that is already a `View` modifier in scope.
        @Bindable var settings = toolbar
        List {
            Section {
                Picker("Pinch", selection: $settings.pinchAction) {
                    ForEach(ToolbarSettings.PinchAction.allCases) { action in
                        Text(action.label).tag(action)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Pinch")
            } footer: {
                Text(settings.pinchAction.detail)
                    .font(.caption)
            }

            Section {
                ForEach(TerminalGesture.allCases) { gesture in
                    row(gesture)
                }
            } header: {
                Text("Gestures")
            } footer: {
                Text("Leave a gesture blank to restore what it does by default. \(TerminalGesture.unsupported)")
                    .font(.caption)
            }

            Section {
                Text("Modifiers: C- / Ctrl+, M- / Opt- / Alt+, S- / Shift+. Named keys: Tab, Enter, Esc, Space, BSpace, arrows, Home, End, PageUp, PageDown, F1–F12. Commas or spaces separate keystrokes and `text:…` sends the rest verbatim followed by Return.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Reset all gestures", role: .destructive) {
                    store.resetAll()
                    editing = nil
                }
                .disabled(store.bindings.isEmpty)
            } footer: {
                Text("Clears every binding above and restores the defaults. Custom "
                     + "keys are cleared from the Shortcuts screen, where they are listed.")
            }
        }
        .navigationTitle("Gestures")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func row(_ gesture: TerminalGesture) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(gesture.label, systemImage: gesture.symbol)
                Spacer()
                if editing != gesture {
                    Button {
                        draft = store.text(for: gesture) ?? ""
                        editing = gesture
                    } label: {
                        Text(store.text(for: gesture) ?? gesture.fallback?.label ?? "Not set")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(store.text(for: gesture) == nil ? .secondary : themes.current.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            if editing == gesture {
                HStack {
                    TextField(gesture.fallback?.label ?? "C-b, n", text: $draft)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { commit(gesture) }
                    Button("Set") { commit(gesture) }
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Clear") {
                        store.set(nil, for: gesture)
                        editing = nil
                    }
                    .foregroundStyle(.secondary)
                }

                // The same live feedback the shortcut editor gives: the error
                // arrives here rather than as a gesture that quietly does
                // nothing.
                if let problem = problem(for: gesture) {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !draft.isEmpty, let bytes = try? ShortcutGrammar.parse(draft).bytes {
                    Text("Sends \(byteName(bytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The draft is checked, not the saved value, so the error appears while
    /// typing rather than only after the fact.
    private func problem(for gesture: TerminalGesture) -> String? {
        guard !draft.isEmpty else { return nil }
        do {
            _ = try ShortcutGrammar.parse(draft)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func commit(_ gesture: TerminalGesture) {
        store.set(draft, for: gesture)
        editing = nil
    }

    private func byteName(_ bytes: [UInt8]) -> String {
        bytes.map { byte in
            switch byte {
            case 0x1B: "ESC"
            case 0x0D: "CR"
            case 0x09: "TAB"
            case 0x02: "^B"
            case 0x20...0x7E: String(UnicodeScalar(byte))
            default: String(format: "0x%02X", byte)
            }
        }
        .joined(separator: " ")
    }
}