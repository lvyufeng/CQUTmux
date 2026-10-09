import SwiftUI

/// The bar's chat-mode face: a native text field that composes a whole message
/// and hands it to the session in one piece.
///
/// It replaces the key bar rather than joining it. The two answer different
/// questions — the keys type *into* the terminal one keystroke at a time, this
/// composes a message *outside* it — and showing both would put a text field
/// and a row of Enter/Esc/arrow keys in the same strip, which is neither one
/// thing nor the other.
///
/// Why a native field at all, when SwiftTerm already accepts keyboard input:
/// the terminal's input goes through `UITextInput` inside the TUI, and a TUI
/// that repaints over the marked range breaks iOS keyboard composition — the
/// CJK case this exists for. A `TextField` outside the terminal is composed by
/// the system, in a view no agent can repaint, and the finished string is what
/// gets delivered.
struct ChatComposerBar: View {
    /// Sends the text. Returns whether it went, so a failed send keeps the
    /// draft rather than dropping it on the floor.
    let send: (String) -> Bool
    /// Writes the draft out without submitting it, for when the user wants to
    /// see it in the session before committing — the same escape hatch a
    /// cut-off prompt needs.
    let insert: (String) -> Void
    @Environment(ThemeStore.self) private var themes

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message the agent…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    // No autocorrection on a field whose text is a command in
                    // prose: turning "sudo" into "Sudoku" would be sent, not
                    // seen. Capitalisation follows it for the same reason.
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        themes.current.backgroundColor.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                    .onSubmit(submit)

                // Insert without submitting, and only while there is something
                // to insert. A second button rather than a long press, because
                // the difference between the two — does the agent act on it or
                // does the line just sit there — is not one a press-and-hold
                // should have to teach.
                if ChatComposer.isSendable(draft) {
                    Button {
                        insert(draft)
                        draft = ""
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Insert without sending")
                }

                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    ChatComposer.isSendable(draft)
                    ? themes.current.accentColor
                    : Color.secondary
                )
                .disabled(!ChatComposer.isSendable(draft))
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(themes.current.barSurface)
    }

    private func submit() {
        // Cleared only when it actually went. A send that failed — the session
        // dropped between composing and pressing — must leave the draft where
        // the user can retry it, because a long prompt is not something to lose
        // to a dropped connection.
        guard send(draft) else { return }
        draft = ""
        // The field keeps focus so a follow-up message does not need a tap to
        // start typing again.
        focused = true
    }
}