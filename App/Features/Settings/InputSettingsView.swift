import SwiftUI

/// Settings → Input: the keyboard bar, the D-pad, and how Option behaves.
struct InputSettingsView: View {
    @State private var input = InputSettings()

    var body: some View {
        List {
            Section {
                Toggle("Option sends Meta", isOn: $input.optionIsMeta)
                Toggle("Hide the key bar with a hardware keyboard",
                       isOn: $input.hideBarWithHardwareKeyboard)
            } header: {
                Label("Keyboard", systemImage: "keyboard")
            } footer: {
                Text("Meta sends Option+letter as Esc then the letter, which is what readline and "
                     + "emacs expect for word motions. Off, Option types the accented character "
                     + "the keyboard is set up for.")
            }

            Section {
                ForEach(input.items) { item in
                    Label(item.label, systemImage: icon(item))
                }
                .onMove { input.move(from: $0, to: $1) }
                .onDelete { offsets in
                    for index in offsets { input.remove(input.items[index]) }
                }

                ForEach(InputSettings.Item.allCases.filter { !input.items.contains($0) }) { item in
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
                ForEach(InputSettings.Corner.allCases) { slot in
                    Picker(slot.label, selection: Binding(
                        get: { input.corner(slot) },
                        set: { input.setCorner(slot, to: $0) }
                    )) {
                        ForEach(InputSettings.CornerAction.allCases) { action in
                            Text(action.label).tag(action)
                        }
                    }
                }
            } header: {
                Label("D-pad corners", systemImage: "square.grid.3x3")
            } footer: {
                Text("Shown only when the D-pad is in the bar above.")
            }
        }
        .navigationTitle("Input")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
    }

    private func icon(_ item: InputSettings.Item) -> String {
        switch item {
        case .control, .escape, .tab: "keyboard"
        case .arrows: "arrow.up.and.down.and.arrow.left.and.right"
        case .dpad: "square.grid.3x3"
        case .clipboard: "doc.on.doc"
        case .pasteImage: "photo"
        case .sessions: "rectangle.grid.1x2"
        case .dictation: "mic"
        case .customKeys: "star"
        }
    }
}