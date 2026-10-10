import Foundation

/// Composing a message for an agent from *outside* the terminal.
///
/// Command mode types straight into the shell: every keystroke goes through
/// SwiftTerm's `UITextInput`, which is the path a TUI owns — and the path a TUI
/// is allowed to disrupt. Two things make that the wrong way to talk to an
/// agent:
///
/// - **CJK.** Composing Chinese with the iOS keyboard means marked text and
///   candidate selection, and a full-screen TUI (an agent's own interface, or a
///   multiplexer's) repaints over the marked range as it arrives. The
///   composition is what breaks, not the delivery: the characters that finally
///   commit can land in the wrong place, in the wrong order, or not at all.
///   Moshi's answer is the same one here — a native iOS text field that the TUI
///   cannot touch, whose finished string is handed over in one piece.
/// - **Shape.** A TUI that reads single keystrokes sees an agent's prompt arrive
///   one byte at a time, as if a person were typing it slowly. It reacts to
///   half-typed input.
///
/// So the composer is a real `TextField`, and delivery is the same thing a
/// paste is: when the program on the other end has turned on bracketed paste,
/// the message is wrapped in `ESC[200~ … ESC[201~` so it arrives as *one paste*
/// rather than as typing, which is what makes a TUI treat it as text to insert
/// instead of keys to interpret. When bracketed paste is off — a plain shell —
/// the markers would be literal garbage, so they are not sent.
///
/// The decision is a pure function of the text and that one mode bit, kept
/// apart from the terminal so it can be run directly by a check: the markers
/// are invisible in a passing test but very visible in a shell that prints them.
enum ChatComposer {
    /// Bracketed-paste markers. `ESC[200~` opens, `ESC[201~` closes.
    static let pasteStart = "\u{1B}[200~"
    static let pasteEnd = "\u{1B}[201~"

    /// Whether there is anything to send. Whitespace alone is not a message —
    /// sending it would put a blank line into the agent's prompt, which reads
    /// as a submit.
    static func isSendable(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The draft with one more piece added — a dictated phrase, or the path of
    /// an uploaded image.
    ///
    /// Chat mode drafts the whole message before it is sent, so voice, typed
    /// text and images all land in the same field and leave as one payload.
    /// The joining is what fails silently: an image path appended to a sentence
    /// with no space between them makes one nonsense token, and one appended to
    /// a field that already ends in a space makes a double space the user never
    /// typed and cannot see. So the rule is a function of the two strings, kept
    /// here where a check can drive it.
    ///
    /// The addition is trimmed at its edges — a dictated phrase arrives with
    /// stray whitespace, and an image path never needs it — but a *newline* at
    /// the end of the draft is respected: it means the user pressed Return
    /// inside the field, and the next piece belongs on its own line.
    static func appending(_ addition: String, to draft: String) -> String {
        let piece = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        if piece.isEmpty { return draft }
        if draft.isEmpty { return piece }
        // A newline or an existing space already separates the two, so adding
        // another would be a space the user did not type.
        if let last = draft.last, last.isWhitespace { return draft + piece }
        return draft + " " + piece
    }

    /// The bytes to write for a message, or nil when there is nothing to send.
    ///
    /// The text is trimmed at the edges only: leading and trailing blank space
    /// is an accident of the keyboard or a paste, never something the user
    /// meant to put in a sentence — but interior newlines are kept, because a
    /// multi-line prompt is a legitimate thing to compose and the composer is
    /// the one place they can be typed on purpose.
    ///
    /// A single Return follows the message so it is *submitted* rather than
    /// left sitting in the input to be confirmed. That is the difference
    /// between chat mode and command mode, and the reason the two exist.
    static func payload(for text: String, bracketed: Bool) -> Data? {
        guard isSendable(text) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = ""
        if bracketed { out += pasteStart }
        out += trimmed
        if bracketed { out += pasteEnd }
        // Carriage return, not newline: this is arriving at a pty in raw mode
        // as if the Enter key were pressed, and Enter is CR.
        out += "\r"
        return Data(out.utf8)
    }
}