import Foundation

/// Parses the shorthand people type into the custom-shortcut editor into the
/// bytes a terminal should receive.
///
/// The grammar is the one Moshi documents, because a shortcut is a thing users
/// bring with them and re-learning it per app is pure friction:
///
///   `C-` `Ctrl+`          Control
///   `M-` `Opt-` `Alt+`    Meta — an ESC before the key, which is what a
///                         terminal sends and what readline/zsh read as Alt
///   `S-` `Shift+`         Shift
///   `F1`…`F12`            function keys
///   named keys            Tab Enter Esc Space BSpace Up Down Left Right
///                         Home End PageUp PageDown
///   `dash` `plus`         literal `-` and `+`, since the bare characters are
///                         modifier separators
///   `,` or a space        separates two keystrokes in one shortcut
///   `,,`                  a literal comma
///   `text:…`              the rest of the step is sent verbatim
///
/// Anything else is rejected with a reason rather than sent as nonsense: a
/// shortcut that types `Contrl-b` into a shell because the modifier was
/// misspelled is worse than one that refuses to be saved.
enum ShortcutGrammar {
    /// One keystroke's worth of bytes. A step is separate from its neighbours
    /// so the editor can label them individually.
    struct Step: Equatable {
        var bytes: [UInt8]
        var label: String
    }

    struct Parsed: Equatable {
        var steps: [Step]
        /// `text:…` means "send this and run it", so the caller appends a
        /// carriage return. Defaulted rather than required, matching Moshi.
        var autoEnter: Bool

        /// The whole shortcut as one byte string, ready for the wire.
        var bytes: [UInt8] {
            var out = steps.flatMap(\.bytes)
            if autoEnter { out.append(0x0D) }
            return out
        }

        /// What the panel shows, e.g. `Ctrl+b, Shift+t`.
        var label: String { steps.map(\.label).joined(separator: ", ") }
    }

    enum ParseError: Error, Equatable, LocalizedError {
        case empty
        case unknownModifier(String)
        case unknownKey(String)
        case functionKeyOutOfRange(String)
        case danglingSeparator

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Enter a shortcut."
            case .unknownModifier(let text):
                return "“\(text)” is not a modifier. Use Ctrl, Opt/Alt or Shift."
            case .unknownKey(let text):
                return "“\(text)” is not a key I know."
            case .functionKeyOutOfRange(let text):
                return "“\(text)” is out of range — function keys run F1 to F12."
            case .danglingSeparator:
                return "The shortcut ends with a separator."
            }
        }
    }

    // MARK: - Entry point

    static func parse(_ input: String) throws -> Parsed {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError.empty }

        // `text:` swallows the rest verbatim, commas and all — it exists so a
        // prompt full of punctuation can be bound without escaping any of it.
        if let rest = text.dropPrefixIfPresent("text:") {
            let body = String(rest)
            guard !body.isEmpty else { throw ParseError.empty }
            return Parsed(
                steps: [Step(bytes: Array(body.utf8), label: body)],
                autoEnter: true
            )
        }

        var steps: [Step] = []
        for raw in try split(text) {
            steps.append(try parseStep(raw))
        }
        return Parsed(steps: steps, autoEnter: false)
    }

    // MARK: - Splitting

    /// Splits on commas and spaces, keeping `,,` as a literal comma. `text:`
    /// is handled before this, so a colon never has to survive splitting.
    private static func split(_ text: String) throws -> [String] {
        var pieces: [String] = []
        var current = ""
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character == "," {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "," {
                    // `,,` is one literal comma, so it belongs to this step.
                    current.append(",")
                    index = text.index(after: next)
                    continue
                }
                pieces.append(current)
                current = ""
            } else if character == " " {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index = text.index(after: index)
        }
        pieces.append(current)

        let steps = pieces.filter { !$0.isEmpty }
        guard !steps.isEmpty else { throw ParseError.empty }
        // A trailing separator produced an empty tail that `filter` dropped,
        // which means the shortcut silently lost a keystroke. Say so instead:
        // `C-b,` is far more likely a typo than "send Ctrl+b, then nothing".
        if pieces.last?.isEmpty == true, pieces.count > 1 {
            throw ParseError.danglingSeparator
        }
        return steps
    }

    // MARK: - One step

    private static func parseStep(_ raw: String) throws -> Step {
        var remainder = raw[...]
        var control = false
        var meta = false
        var shift = false
        var labelPrefix = ""

        // Modifiers are a prefix chain, consumed left to right. Matching is
        // case-insensitive because `Ctrl+b` and `ctrl+b` are the same key, and
        // a grammar that only accepts one spelling is a grammar that rejects
        // what people actually type.
        loop: while true {
            for (prefix, canonical, apply) in modifierPrefixes {
                // A lone prefix with nothing after it is a typo, not a key.
                guard remainder.count > prefix.count,
                      remainder.lowercased().hasPrefix(prefix) else { continue }
                apply(&control, &meta, &shift)
                // Only the first spelling of a repeated modifier is shown, so
                // `Ctrl+Ctrl+b` does not label itself as if it were two chords.
                if !labelPrefix.contains(canonical) { labelPrefix += canonical }
                remainder = remainder.dropFirst(prefix.count)
                continue loop
            }
            break loop
        }

        let body = String(remainder)
        guard !body.isEmpty else { throw ParseError.unknownKey(raw) }

        // A named key has to be the whole step: `Esc` is the Escape key, but
        // `Escape` followed by more characters is not a key name.
        if let named = namedKeys[body.lowercased()] {
            return Step(bytes: applyModifiers(named, control: control, meta: meta),
                        label: labelPrefix + canonicalName(body))
        }

        if body.count > 1, body.lowercased().hasPrefix("f"), let number = Int(body.dropFirst()) {
            guard let bytes = functionKeys[number] else {
                throw number > 12 ? ParseError.functionKeyOutOfRange(body) : ParseError.unknownKey(body)
            }
            // Shift on a function key is F13–F24 in xterm, which is not worth
            // guessing at; the modifier is reported as unsupported instead.
            guard !control, !meta, !shift else { throw ParseError.unknownModifier(body) }
            return Step(bytes: bytes, label: "F\(number)")
        }

        // A bare multi-character word is a mistyped key or modifier, not text:
        // `Contrl-b` is someone meaning Ctrl+B, and `nosuchkey` is someone
        // meaning a key that does not exist. Both are refused rather than
        // typed into the shell, which is why `text:` exists as the explicit
        // way to say "yes, I really do mean these characters".
        guard control || meta || shift || body.count == 1 else {
            throw ParseError.unknownKey(body)
        }

        // Otherwise the modifier applies to the *first* character and the
        // remainder is sent literally. That is what makes `Ctrl+b1` a tmux
        // chord — Ctrl+B, then a literal `1`.
        guard let first = body.first else { throw ParseError.unknownKey(raw) }
        var bytes = encodeFirst(first, control: control, meta: meta, shift: shift)
        bytes.append(contentsOf: Array(body.dropFirst().utf8))
        return Step(bytes: bytes, label: labelPrefix + String(body))
    }

    /// Encodes one character with its modifiers. Shift on a letter means the
    /// capital and on a digit the shifted symbol, because a terminal has no
    /// separate shift code point to send.
    private static func encodeFirst(
        _ character: Character, control: Bool, meta: Bool, shift: Bool
    ) -> [UInt8] {
        guard let ascii = character.asciiValue else {
            // Non-ASCII (a CJK character, say) has no control form; send it as
            // UTF-8 so a shortcut can still type it.
            var out = Array(String(character).utf8)
            if meta { out.insert(0x1B, at: 0) }
            return out
        }

        var value = ascii
        if shift, !control {
            let upper = String(character).uppercased()
            if upper != String(character), let scalar = upper.unicodeScalars.first, scalar.isASCII {
                value = UInt8(scalar.value)
            } else if let symbol = shiftedSymbols[character] {
                var out = Array(symbol.utf8)
                if meta { out.insert(0x1B, at: 0) }
                return out
            }
        }
        if control, let mapped = controlByte(value) { value = mapped }
        var out = [value]
        // Meta is the ESC prefix, which is what a terminal actually sends.
        if meta { out.insert(0x1B, at: 0) }
        return out
    }

    /// Modifier prefixes, longest first so `ctrl+` wins over `c-`.
    private static let modifierPrefixes: [(String, String, (inout Bool, inout Bool, inout Bool) -> Void)] = [
        ("ctrl+", "Ctrl+", { c, _, _ in c = true }),
        ("shift+", "Shift+", { _, _, s in s = true }),
        ("alt+", "Alt+", { _, m, _ in m = true }),
        ("opt-", "Alt+", { _, m, _ in m = true }),
        ("opt+", "Alt+", { _, m, _ in m = true }),
        ("c-", "Ctrl+", { c, _, _ in c = true }),
        ("m-", "Alt+", { _, m, _ in m = true }),
        ("s-", "Shift+", { _, _, s in s = true }),
    ]

    private static func applyModifiers(_ bytes: [UInt8], control: Bool, meta: Bool) -> [UInt8] {
        var out = bytes
        if control, out.count == 1, let first = out.first, let mapped = controlByte(first) {
            out = [mapped]
        }
        if meta { out.insert(0x1B, at: 0) }
        return out
    }

    /// Canonical spelling for a named key, so the panel reads the same whether
    /// the user typed `esc`, `ESC` or `Esc`.
    private static func canonicalName(_ body: String) -> String {
        let lower = body.lowercased()
        switch lower {
        case "esc", "escape": return "Esc"
        case "bspace", "backspace": return "BSpace"
        case "pageup": return "PageUp"
        case "pagedown": return "PageDown"
        case "dash": return "-"
        case "plus": return "+"
        default: return lower.capitalized
        }
    }

    /// The control-character form of a byte, or nil when there isn't one.
    private static func controlByte(_ byte: UInt8) -> UInt8? {
        switch byte {
        // Ctrl+A…Ctrl+Z are 0x01…0x1A. Lower and upper case are the same key.
        case 0x41...0x5A: return byte - 0x40
        case 0x61...0x7A: return byte - 0x60
        case 0x20: return 0x00            // Ctrl+Space is NUL
        case 0x3F: return 0x7F            // Ctrl+? is DEL
        case 0x40: return 0x00            // Ctrl+@ is NUL
        case 0x5B: return 0x1B            // Ctrl+[
        case 0x5C: return 0x1C            // Ctrl+\
        case 0x5D: return 0x1D            // Ctrl+]
        case 0x5E: return 0x1E            // Ctrl+^
        case 0x5F: return 0x1F            // Ctrl+_
        default: return nil
        }
    }

    private static let namedKeys: [String: [UInt8]] = [
        "tab": [0x09],
        "enter": [0x0D],
        "return": [0x0D],
        "esc": [0x1B],
        "escape": [0x1B],
        "space": [0x20],
        "bspace": [0x7F],
        "backspace": [0x7F],
        "up": [0x1B, 0x5B, 0x41],
        "down": [0x1B, 0x5B, 0x42],
        "right": [0x1B, 0x5B, 0x43],
        "left": [0x1B, 0x5B, 0x44],
        "home": [0x1B, 0x5B, 0x48],
        "end": [0x1B, 0x5B, 0x46],
        "pageup": [0x1B, 0x5B, 0x35, 0x7E],
        "pagedown": [0x1B, 0x5B, 0x36, 0x7E],
        // `dash` and `plus` exist because the bare characters are separators.
        "dash": [0x2D],
        "plus": [0x2B],
    ]

    private static let functionKeys: [Int: [UInt8]] = [
        1: [0x1B, 0x4F, 0x50], 2: [0x1B, 0x4F, 0x51], 3: [0x1B, 0x4F, 0x52], 4: [0x1B, 0x4F, 0x53],
        5: [0x1B, 0x5B, 0x31, 0x35, 0x7E], 6: [0x1B, 0x5B, 0x31, 0x37, 0x7E],
        7: [0x1B, 0x5B, 0x31, 0x38, 0x7E], 8: [0x1B, 0x5B, 0x31, 0x39, 0x7E],
        9: [0x1B, 0x5B, 0x32, 0x30, 0x7E], 10: [0x1B, 0x5B, 0x32, 0x31, 0x7E],
        11: [0x1B, 0x5B, 0x32, 0x33, 0x7E], 12: [0x1B, 0x5B, 0x32, 0x34, 0x7E],
    ]

    private static let shiftedSymbols: [Character: String] = [
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%",
        "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
        "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|",
        ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~",
    ]

    }

private extension String {
    /// `dropFirst` with a prefix check, or nil when it does not match.
    func dropPrefixIfPresent(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}