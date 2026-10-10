import Foundation

/// One piece of a message's prose, split by how it should be drawn.
///
/// The chat used to render a whole message as one `Text`. That is wrong in a
/// way a screenshot cannot show: a fenced code block drawn as prose loses its
/// line structure and its monospacing, and an inline image drawn as prose shows
/// the reader the literal characters `![alt](url)`. Both read as "the agent sent
/// rubbish" rather than "the app did not parse it".
///
/// Splitting is done here, apart from the view, because every rule in it fails
/// silently — a fence that is not recognised produces one prose blob that still
/// *renders*, just wrongly — and because the same split has to hold for tests,
/// previews and any future export. It is Foundation-only so a check can run the
/// real parser instead of a copy of it.
enum ChatMarkdown {
    /// One run of a message.
    enum Segment: Equatable {
        /// Ordinary text, including any inline markup left to SwiftUI to draw.
        case prose(String)
        /// A fenced code block. `language` is the fence's info string's first
        /// word, when there is one — it picks the syntax highlighting and is
        /// empty for a bare ``` fence.
        case code(language: String?, body: String)
        /// An inline image. `alt` is the bracketed text and may be empty.
        case image(url: String, alt: String)
    }

    /// Splits `text` into segments in the order they appear.
    ///
    /// Prose between blocks is preserved, including the blank lines that
    /// separate paragraphs (Markdown's own blank-line rule is a rendering
    /// concern, not a splitting one). Empty prose runs are dropped rather than
    /// emitted, so a message that is nothing but a code block yields one
    /// segment and not three.
    static func segments(in text: String) -> [Segment] {
        var result: [Segment] = []
        var prose: [String] = []
        let lines = text.components(separatedBy: "\n")
        var index = 0

        func flushProse() {
            let joined = trimBlankEdges(prose)
            prose = []
            guard !joined.isEmpty else { return }
            appendProse(joined, into: &result)
        }

        while index < lines.count {
            let line = lines[index]
            guard let fence = fenceStart(line) else {
                prose.append(line)
                index += 1
                continue
            }
            flushProse()
            // Everything to the matching closing fence is code. An unclosed
            // fence runs to the end of the message — CommonMark's rule, and the
            // right one here: the alternative is to fall back to prose and show
            // the reader the backticks, which is the failure this exists to
            // avoid.
            var body: [String] = []
            index += 1
            while index < lines.count, !fence.closes(lines[index]) {
                body.append(lines[index])
                index += 1
            }
            if index < lines.count { index += 1 }  // consume the closing fence
            result.append(.code(language: fence.language, body: body.joined(separator: "\n")))
        }
        flushProse()
        return result
    }

    /// Drops whole blank lines from the start and end of a prose run.
    ///
    /// Not `trimmingCharacters(in:)`: that removes horizontal whitespace too,
    /// and four leading spaces are an *indented code block* — trimming them
    /// turns code into ordinary text, which is the same class of silent
    /// misrender this whole type exists to prevent. Only the empty separating
    /// lines go; a line with content in it keeps every space it has.
    private static func trimBlankEdges(_ lines: [String]) -> String {
        func isBlank(_ line: String) -> Bool {
            line.allSatisfy { $0 == " " || $0 == "\t" }
        }
        var start = 0
        var end = lines.count
        while start < end, isBlank(lines[start]) { start += 1 }
        while end > start, isBlank(lines[end - 1]) { end -= 1 }
        return lines[start..<end].joined(separator: "\n")
    }

    /// An opening fence, with the length and character needed to close it.
    private struct Fence {
        let marker: Character
        let count: Int
        let language: String?

        /// Whether `line` closes this fence.
        ///
        /// CommonMark's two rules, both of which a naive "is it ```?" check gets
        /// wrong: the closing fence must use the *same* character (a `~~~` line
        /// inside a ``` block is code, not an ending) and must be *at least as
        /// long* (a ``` line does not close a ```` block, because the extra
        /// backtick is content).
        func closes(_ line: String) -> Bool {
            let stripped = line.drop { $0 == " " }
            guard stripped.first == marker else { return false }
            let run = stripped.prefix { $0 == marker }
            guard run.count >= count else { return false }
            // A closing fence carries nothing but its marker and whitespace; a
            // longer line is a paragraph that happens to start with backticks.
            return stripped.dropFirst(run.count).allSatisfy { $0 == " " || $0 == "\t" }
        }
    }

    /// Reads `line` as an opening fence, or nil.
    private static func fenceStart(_ line: String) -> Fence? {
        // Up to three leading spaces, per CommonMark. Four makes it an indented
        // code block — and indented code is exactly how a fence gets *shown to
        // the reader* instead of opening a block, so this is the difference
        // between correct rendering and a message full of stray backticks.
        var spaces = 0
        var rest = Substring(line)
        while rest.first == " ", spaces < 4 { spaces += 1; rest = rest.dropFirst() }
        guard spaces < 4, let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let run = rest.prefix { $0 == marker }
        // Three is the minimum. One or two backticks are inline code, which is a
        // span inside the prose and not a block.
        guard run.count >= 3 else { return nil }
        let info = rest.dropFirst(run.count).trimmingCharacters(in: .whitespaces)

        // A backtick fence's info string may not itself contain a backtick —
        // that is how CommonMark keeps a run of backticks inside inline code
        // from being read as a fence. A tilde fence has no such rule.
        if marker == "`" && info.contains("`") { return nil }

        // The info string is `language` plus anything else the author added
        // (`swift title="x"`). Only the first word names the language.
        let language = info.split(separator: " ").first.map(String.init)
        return Fence(
            marker: marker,
            count: run.count,
            language: (language?.isEmpty ?? true) ? nil : language
        )
    }

    /// Appends `text` as prose, with any inline images lifted out of it.
    ///
    /// A message's prose becomes a `Text`; an image cannot, so the two have to
    /// be separate segments. Splitting rather than rendering the Markdown
    /// wholesale is what keeps `![alt](url)` from being shown to the reader as
    /// its own source when the URL is not loadable.
    private static func appendProse(_ text: String, into result: inout [Segment]) {
        var remaining = Substring(text)
        while let open = remaining.range(of: "![") {
            // An image is `![alt](url)`. If either bracket is missing this is
            // not an image, and the rest is ordinary text.
            guard let closeBracket = remaining.range(of: "](", range: open.upperBound..<remaining.endIndex),
                  let closeParen = parenEnd(in: remaining, from: closeBracket.upperBound)
            else { break }

            let before = trimBlankEdges(
                String(remaining[remaining.startIndex..<open.lowerBound])
                    .components(separatedBy: "\n")
            )
            if !before.isEmpty { result.append(.prose(before)) }
            let alt = String(remaining[open.upperBound..<closeBracket.lowerBound])
            let url = String(remaining[closeBracket.upperBound..<closeParen.lowerBound])
            result.append(.image(url: unquoted(url), alt: alt))
            remaining = remaining[closeParen.upperBound...]
        }
        let tail = trimBlankEdges(String(remaining).components(separatedBy: "\n"))
        if !tail.isEmpty { result.append(.prose(tail)) }
    }

    /// The index just past the `)` that closes an image's URL.
    ///
    /// Counts nested parens so a URL that contains its own `(...)` — the kind a
    /// Wikipedia link has — is not cut short at the first one.
    private static func parenEnd(in text: Substring, from start: String.Index) -> Range<String.Index>? {
        // Starts at 1, because the opening paren is *behind* `start`: the scan
        // begins at the first character of the URL. Counting from zero made the
        // first `)` close to -1 and never return, so no image was ever
        // recognised — the whole image path was dead and every message showed
        // its `![alt](url)` as literal text.
        var depth = 1
        var index = start
        while index < text.endIndex {
            switch text[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return index..<text.index(after: index) }
            default: break
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Strips the `"title"` some images carry after their URL, which is not part
    /// of the address and would be fetched as one.
    private static func unquoted(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return trimmed }
        let address = String(trimmed[trimmed.startIndex..<space])
        let title = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
        return title.hasPrefix("\"") && title.hasSuffix("\"") && title.count >= 2 ? address : trimmed
    }
}