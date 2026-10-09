import SwiftUI

/// Settings → Input: the keyboard bar, the D-pad, and how Option behaves.
struct InputSettingsView: View {
    @State private var input = InputSettings()

    var body: some View {
        List {
            Section {
                Toggle("Option sends Meta", isOn: $input.optionIsMeta)
                Toggle("Chat mode", isOn: $input.chatMode)
                Toggle("Hide the key bar with a hardware keyboard",
                       isOn: $input.hideBarWithHardwareKeyboard)
                    .disabled(input.chatMode)
                Toggle("Hide the window row", isOn: $input.hidesWindowRow)
                    .disabled(input.chatMode)
            } header: {
                Label("Keyboard", systemImage: "keyboard")
            } footer: {
                Text(keyboardFooter)
            }

            Section {
                ForEach(input.items) { item in
                    Label(item.label, systemImage: icon(item))
                }
                .onMove { input.move(from: $0, to: $1) }
                .onDelete { offsets in
                    for index in offsets { input.remove(input.items[index]) }
                }

                // `allItems`, not `allCases`: the off-by-default items (Enter,
                // Backspace, the keyboard toggle) are exactly the ones someone
                // has to be able to add, and `allCases` order would list them
                // among the defaults with no sign of which is which.
                ForEach(InputSettings.allItems.filter { !input.items.contains($0) }) { item in
                    Button {
                        input.restore(item)
                    } label: {
                        Label("Add \(item.label)", systemImage: "plus")
                    }
                }
            } header: {
                Label("Key bar", systemImage: "keyboard.badge.ellipsis")
            } footer: {
                Text("Drag to reorder, swipe to remove. The D-pad adds a four-way pad with two "
                     + "bindable corners; the arrows below it always send arrows.")
            }

            Section {
                Toggle("Two-finger swipes drive the multiplexer", isOn: $input.muxGestures)
            } header: {
                Label("Terminal gestures", systemImage: "hand.draw")
            } footer: {
                Text("Sideways switches pane; up and down switches tab, or opens "
                     + "herdr's workspace navigator, which has no next-workspace key "
                     + "of its own. The keys sent are the host's own — check them under "
                     + "Settings → Multiplexer. Off, the two-finger drag scrolls "
                     + "scrollback and sends mouse-wheel events as it always did.")
            }

            Section {
                ForEach(InputSettings.Corner.allCases) { slot in
                    Picker(slot.label, selection: Binding(
                        get: { input.corner(slot) },
                        set: { input.setCorner(slot, to: $0) }
                    )) {
                        ForEach(InputSettings.CornerAction.allCases) { action in
                            Text(action.label).tag(action)
                        }
                    }
                    if input.corner(slot) == .custom {
                        TextField(
                            "Shortcut",
                            text: Binding(
                                get: { input.cornerShortcut(slot) ?? "" },
                                set: { input.setCornerShortcut($0, for: slot) }
                            )
                        )
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                    }
                }
            } header: {
                Label("D-pad corners", systemImage: "square.grid.3x3")
            } footer: {
                Text("Shown only when the D-pad is in the bar above. "
                     + "A custom shortcut takes the same grammar as the key bar's bindings.")
            }
        }
        .navigationTitle("Input")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
    }

    /// Extracted from the view builder: the concatenation of four literals
    /// inside a `Text` in a `Section` footer is more than the type checker
    /// wants to do in one expression, and it reports that as a confusing
    /// "unable to type-check in reasonable time" rather than as a real error.
    private var keyboardFooter: String {
        "Meta sends Option+letter as Esc then the letter, which is what readline and "
        + "emacs expect for word motions. Off, Option types the accented character "
        + "the keyboard is set up for. The window row taps straight to tmux window "
        + "1\u{2013}9, above the keys; windows past 9 need the session picker. "
        + "Chat mode replaces the key bar with a message field: you compose a whole "
        + "line outside the terminal and it is delivered in one piece, which is what "
        + "to reach for when a full-screen agent interface mangles Chinese or "
        + "Japanese composition as it repaints."
    }

    private func icon(_ item: InputSettings.Item) -> String {
        switch item {
        case .control, .escape, .tab: "keyboard"
        case .enter: "return"
        case .backspace: "delete.left"
        case .keyboard: "keyboard.chevron.compact.down"
        case .showKeyboard: "keyboard"
        case .arrows: "arrow.up.and.down.and.arrow.left.and.right"
        case .dpad: "square.grid.3x3"
        case .clipboard: "doc.on.doc"
        case .pasteImage: "photo"
        case .sessions: "rectangle.grid.1x2"
        case .history: "clock.arrow.circlepath"
        case .dictation: "mic"
        case .customKeys: "star"
        }
    }
}