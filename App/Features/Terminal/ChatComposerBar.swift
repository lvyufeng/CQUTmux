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
    /// The draft, owned by the screen rather than by this bar: a dictated
    /// phrase and an uploaded image's path have to land in the same field, and a
    /// field this bar owned privately could not receive them.
    @Binding var draft: String
    /// Sends the text. Returns whether it went, so a failed send keeps the
    /// draft rather than dropping it on the floor.
    let send: (String) -> Bool
    /// Writes the draft out without submitting it, for when the user wants to
    /// see it in the session before committing — the same escape hatch a
    /// cut-off prompt needs.
    let insert: (String) -> Void
    /// Opens the attachment sources. The chosen image's path comes back through
    /// `draft`, so an image and a sentence are one message.
    var attach: () -> Void = {}
    /// The screen's dictation engine, for the mic button.
    ///
    /// Passed in rather than owned here because the transcript has to reach the
    /// draft through the same route whatever started it, and that route —
    /// `ChatComposer.appending` — is the screen's. A bar that built its own
    /// engine would deliver into a second path, and a phrase started in command
    /// mode before switching would be invisible to it.
    var dictation: Dictation? = nil
    /// The in-flight partial from a streaming engine, shown above the field.
    var preview: String = ""
    @Environment(ThemeStore.self) private var themes

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            // The partial sits here rather than on the key bar, which chat mode
            // replaces wholesale. A streaming engine reports word by word and
            // the phrase only arrives at the end, so with nowhere to draw it a
            // long sentence would look like nothing was being heard.
            if !preview.isEmpty {
                HStack {
                    Text(preview)
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }
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

                // Attach first: it is the one control that works on an empty
                // field (an image alone is a message), so it cannot be gated on
                // there being a draft the way the two send controls are.
                Button(action: attach) {
                    Image(systemName: "paperclip")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Add an image")

                // Dictation, next to attach: both work on an empty field — a
                // spoken phrase alone is a message — so neither can be gated on
                // there being a draft. Chat mode replaces the key bar, which is
                // the only other place this control lives, so without it there
                // was no way to start dictation from inside the composer at all.
                if let dictation {
                    Button {
                        dictation.toggle(locale: dictation.locale ?? .current)
                    } label: {
                        Image(systemName: dictation.isListening ? "waveform" : "mic")
                            .symbolEffect(.variableColor, isActive: dictation.isListening)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.bordered)
                    .tint(dictation.isListening ? themes.current.accentColor : nil)
                    .disabled(!dictation.isReady)
                    .accessibilityLabel(dictation.isListening ? "Stop dictating" : "Dictate a message")
                    .accessibilityHint(dictation.setupHint ?? "")
                }

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