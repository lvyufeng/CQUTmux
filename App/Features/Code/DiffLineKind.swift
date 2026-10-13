import Foundation

/// What one line of a unified diff is, so a reader can colour it.
///
/// Classifying a line is not a test of its prefix, because a line's spelling
/// does not decide what it is — its position does. `--- a/x` is git's file
/// header in the preamble and a *removed* line whose content is `-- a/x` inside
/// a hunk; the two are byte-identical. The prefix rule this replaced excepted
/// the header spellings by name, so a hunk whose content happened to spell one
/// was painted as a header, and the reader was shown the file's own line as
/// git's bookkeeping. Only the hunk state tells them apart, so the state is
/// carried through the diff here rather than guessed at per line.
///
/// The colour mapping is deliberately not here: this file is compiled on its
/// own by `scripts/diffline-check.sh`, so it must not import SwiftUI, and
/// mapping a kind to a `Color` is the view layer's decision anyway.
enum DiffLineKind: Equatable {
    /// A `+` line inside a hunk.
    case added
    /// A `-` line inside a hunk.
    case removed
    /// A ` ` line inside a hunk: the text both versions keep.
    case context
    /// An `@@ … @@` header. Also the line that opens the hunk for everything
    /// that follows it.
    case hunkHeader
    /// `\ No newline at end of file` — git's annotation of the line above it.
    /// Its own case because it sits *inside* a hunk (the lines after it are
    /// still that hunk's content) while being no line of either version of the
    /// file, so neither context nor metadata describes it.
    case noNewline
    /// Everything outside a hunk: `diff --git`, `index`, `new file mode`,
    /// `Binary files … differ`, the `---`/`+++` pair, and whatever else git
    /// writes between hunks. One case rather than one per spelling because git
    /// keeps adding to that vocabulary (rename and copy sections, submodules),
    /// and an unrecognised preamble line misread as content is a lie about the
    /// file; "not in a hunk" is the only fact the classifier can vouch for.
    case metadata

    /// One line of a diff, with its kind already decided.
    struct Line: Equatable {
        var kind: DiffLineKind
        /// The line verbatim, marker and all. It is what the view draws — the
        /// kind only decides the colour — so a copy of the diff keeps the
        /// `+`/`-` markers that make it a diff.
        var text: String
    }

    /// Every line of a unified diff, classified, in order.
    static func lines(in diff: String) -> [Line] {
        // `omittingEmptySubsequences: false`, or a blank context line would be
        // dropped and every kind after it would describe the wrong line.
        var raw = diff.split(separator: "\n", omittingEmptySubsequences: false)
        // A diff ends with a newline, which splits into a final empty element
        // that is not a line of the diff. Left in, it draws a blank row under
        // the last line.
        if raw.last?.isEmpty == true { raw.removeLast() }

        var result: [Line] = []
        // A hunk has no closing marker — it ends where the next file's section
        // begins — so "inside a hunk" is state that only a `diff ` line clears.
        var inHunk = false

        for line in raw {
            let text = String(line)

            if text.hasPrefix("diff ") {
                // `diff --git` from git, `diff -u`/`diff -ru` from plain diff:
                // either way the next file's preamble starts here. This is what
                // keeps the *second* file's `---`/`+++` headers from being read
                // as changes to the first.
                inHunk = false
                result.append(Line(kind: .metadata, text: text))
            } else if text.hasPrefix("@@") {
                inHunk = true
                result.append(Line(kind: .hunkHeader, text: text))
            } else if !inHunk {
                // The preamble. `---` and `+++` are not special-cased here: they
                // are metadata by virtue of where they are, which is the whole
                // point of classifying by position.
                result.append(Line(kind: .metadata, text: text))
            } else if text.hasPrefix("+") {
                result.append(Line(kind: .added, text: text))
            } else if text.hasPrefix("-") {
                result.append(Line(kind: .removed, text: text))
            } else if text.hasPrefix(" ") {
                result.append(Line(kind: .context, text: text))
            } else if text.hasPrefix("\\") {
                // Matched by the prefix, not by the sentence: the message is
                // long and English, and a changed wording must not fall through
                // to a content kind.
                result.append(Line(kind: .noNewline, text: text))
            } else {
                // Nothing git writes inside a hunk lands here. A blank line
                // does — a diff whose blank context lines lost their single
                // space, as they do when something in the path trims trailing
                // whitespace. Calling it metadata rather than context is the
                // honest answer: a guess would show a line the file never had.
                result.append(Line(kind: .metadata, text: text))
            }
        }
        return result
    }
}