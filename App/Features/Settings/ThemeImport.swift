import Foundation

/// Reads a theme from the two forms Moshi hands one over in: a JSON document,
/// and a `moshi-theme:` string carrying that JSON base64-encoded.
///
/// Both exist because the same theme travels different ways — a QR code needs a
/// compact printable payload, a file on disk needs to stay human-editable, and
/// the gallery serves them as plain JSON. Parsing accepts either rather than
/// making the caller know which it has, since a string that fails as JSON is
/// worth one attempt at base64 before being rejected.
///
/// The format is Moshi's v1, kept exactly — including the rule that `mode` must
/// be stated rather than inferred. Guessing dark/light from the colours is the
/// kind of convenience that is right most of the time and wrong in a way the
/// user cannot correct.
enum ThemeImport {
    enum Failure: Error, LocalizedError, Equatable {
        case notJSON
        case unsupportedVersion(Int?)
        case missing(String)
        case badColor(String)

        var errorDescription: String? {
            switch self {
            case .notJSON:
                "That doesn't look like a theme — no JSON was found in it."
            case .unsupportedVersion(let v):
                "This theme is version \(v.map(String.init) ?? "unknown"); this build reads version 1."
            case .missing(let field):
                "The theme is missing its \(field)."
            case .badColor(let value):
                "“\(value)” is not a colour."
            }
        }
    }

    /// The prefix Moshi uses on a copied theme. Accepting ours as well would be
    /// a second spelling of the same thing, so a theme copied out of CQUTmux
    /// can be pasted into an app that only knows the original.
    static let prefix = "moshi-theme:"

    /// Parses either form. The order matters: JSON is tried first because a
    /// base64 blob can only be one thing, while a JSON document that begins
    /// with a `{` is unambiguous.
    static func parse(_ text: String) -> Result<TerminalTheme, Failure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.notJSON) }

        if trimmed.hasPrefix("{") {
            return parse(json: Data(trimmed.utf8))
        }
        if let range = trimmed.range(of: prefix) {
            let payload = String(trimmed[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: payload) else { return .failure(.notJSON) }
            return parse(json: data)
        }
        // A bare base64 blob with no prefix, which is what a QR code holding
        // only the payload would carry.
        if let data = Data(base64Encoded: trimmed) {
            return parse(json: data)
        }
        return .failure(.notJSON)
    }

    /// Encodes a theme the way Moshi does, so it can be copied out and pasted
    /// into another app or read back by our own parser.
    static func string(for theme: TerminalTheme) -> String {
        // A theme that could not be encoded yields an empty payload rather than
        // the bare prefix: the prefix alone parses as "no JSON here", which is
        // the honest failure, while a prefix with garbage after it would look
        // like a corrupt theme.
        guard let data = try? JSONSerialization.data(withJSONObject: json(for: theme)) else {
            return ""
        }
        return prefix + data.base64EncodedString()
    }

    // MARK: - JSON

    private static func parse(json data: Data) -> Result<TerminalTheme, Failure> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.notJSON)
        }

        // Version is checked before anything else, so a future format fails
        // with "version 2" rather than a misleading complaint about a missing
        // field that was renamed.
        let version = root["v"] as? Int
        guard version == 1 else { return .failure(.unsupportedVersion(version)) }

        guard let name = (root["name"] as? String)?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty
        else { return .failure(.missing("name")) }

        guard let mode = root["mode"] as? String, mode == "dark" || mode == "light" else {
            return .failure(.missing("mode"))
        }

        guard let colors = root["colors"] as? [String: Any] else {
            return .failure(.missing("colors"))
        }

        guard let background = color(colors["background"]) else {
            return .failure(.missing("background"))
        }
        guard let foreground = color(colors["foreground"]) else {
            return .failure(.missing("foreground"))
        }

        // The sixteen, in the order the palette expects: the eight base colours
        // first, then the eight brights. They are *not* interleaved — appending
        // each bright next to its base would put brightBlack where red belongs,
        // and every colour in the imported theme would be wrong without the
        // import failing.
        //
        // Fallbacks as Moshi documents them: a missing bright colour is its
        // base colour, and a missing base colour is the foreground. Deriving
        // rather than refusing lets a theme state only what it cares about.
        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        var base: [String] = []
        var bright: [String] = []
        for name in names {
            // A stated value that does not parse is a typo worth reporting; an
            // absent one falls back. The two cases are different mistakes.
            func read(_ key: String, fallback: String) -> Result<String, Failure> {
                guard let raw = colors[key], !(raw is NSNull) else { return .success(fallback) }
                guard let parsed = color(raw) else { return .failure(.badColor("\(raw)")) }
                return .success(parsed)
            }
            let baseColor: String
            switch read(name, fallback: foreground) {
            case .success(let value): baseColor = value
            case .failure(let failure): return .failure(failure)
            }
            let brightName = "bright" + name.prefix(1).uppercased() + name.dropFirst()
            switch read(brightName, fallback: baseColor) {
            case .success(let value): bright.append(value)
            case .failure(let failure): return .failure(failure)
            }
            base.append(baseColor)
        }
        let ansi = base + bright

        let cursor = color(colors["cursor"]) ?? foreground
        let selection = color(colors["selectionBackground"])
        // A theme has no accent field in the format; the green from its own
        // palette is the closest thing it states, and matches what every
        // built-in theme here leaves in `ansi[2]`.
        let accent = ansi[2]

        return .success(TerminalTheme(
            id: "imported-" + slug(name),
            name: name,
            dark: mode == "dark",
            background: background,
            foreground: foreground,
            cursor: cursor,
            accent: accent,
            selection: selection,
            ansi: ansi
        ))
    }

    /// The JSON a theme would be written as, used to copy one out.
    private static func json(for theme: TerminalTheme) -> [String: Any] {
        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        var colors: [String: Any] = [
            "background": "#" + theme.background,
            "foreground": "#" + theme.foreground,
            "cursor": "#" + theme.cursor,
        ]
        for (index, base) in names.enumerated() {
            colors[base] = "#" + theme.ansi[index]
            let bright = "bright" + base.prefix(1).uppercased() + base.dropFirst()
            colors[bright] = "#" + theme.ansi[index + 8]
        }
        if let selection = theme.selection { colors["selectionBackground"] = "#" + selection }
        return ["v": 1, "name": theme.name, "mode": theme.dark ? "dark" : "light", "colors": colors]
    }

    /// `#rrggbb` or `#rgb`, with or without the `#`, to lowercase `rrggbb`.
    ///
    /// Both lengths are accepted because the format documents both, and a
    /// three-digit colour that was refused would be a theme the author could
    /// see was fine.
    private static func color(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        var hex = text.trimmingCharacters(in: .whitespaces).lowercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 3 || hex.count == 6,
              hex.allSatisfy({ $0.isHexDigit })
        else { return nil }
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        return hex
    }

    /// A stable id from the name, so importing the same theme twice replaces it
    /// rather than piling up duplicates in the list.
    private static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        let allowed = lowered.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(allowed).split(separator: "-").joined(separator: "-")
    }
}