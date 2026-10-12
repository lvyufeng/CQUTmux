import Foundation

/// Laying a unified diff out side by side.
///
/// A phone is too narrow for two full columns of source, so this is not a
/// faithful two-pane editor view. It is the *shape* of the change: the removed
/// lines on the left, the added lines on the right, paired so a modification
/// reads as one row rather than as an unrelated deletion and insertion.
///
/// The pairing is the part that cannot be eyeballed, and it fails silently in
/// both directions: pair too eagerly and an unrelated deletion and insertion —
/// two lines that merely happen to be adjacent — read as one edit the agent
/// never made; pair too rarely and every modification reads as a whole-line
/// rewrite, which is exactly the noise this layout exists to remove. So the
/// rule is decided here, apart from the view, and checked against real hunks.
enum SideBySideDiff {
    /// One line as it appears in the hunk.
    struct Line: Equatable {
        enum Kind: Equatable { case context, added, removed }
        var kind: Kind
        /// Without the leading `+`/`-`/space. The marker is the layout's job
        /// now, and leaving it in shows every row beginning with punctuation.
        var text: String
    }

    /// One row of the paired output.
    struct Row: Equatable {
        /// The left (old) side, or nil when the row is a pure insertion.
        var left: Line?
        /// The right (new) side, or nil when the row is a pure deletion.
        var right: Line?
        /// What the row is, for tinting. A modification — a removed line paired
        /// with an added one — is neither of the two originals and has to be
        /// distinguishable, or the pairing is invisible.
        var kind: Kind

        enum Kind: Equatable { case context, added, removed, modified }

        var isChange: Bool { kind != .context }
    }

    /// One hunk: the header and its paired rows.
    struct Hunk: Equatable {
        /// The raw `@@ … @@` line, kept verbatim.
        var header: String
        var rows: [Row]
        var added: Int
        var removed: Int
    }

    /// The whole diff as hunks. Lines before the first `@@` — the `diff --git`,
    /// `index`, `---` and `+++` headers — are dropped rather than laid out:
    /// they are git's metadata, not content, and putting them in a column
    /// would show `+++ b/file` beside `--- a/file` as though the file had
    /// added and removed its own path.
    static func hunks(in diff: String) -> [Hunk] {
        var result: [Hunk] = []
        var header: String?
        var pendingRemoved: [Line] = []
        var pendingAdded: [Line] = []
        var rows: [Row] = []
        var added = 0
        var removed = 0

        func flushPairs() {
            let pairs = min(pendingRemoved.count, pendingAdded.count)
            for i in 0..<pairs {
                rows.append(Row(left: pendingRemoved[i], right: pendingAdded[i], kind: .modified))
            }
            for i in pairs..<pendingRemoved.count {
                rows.append(Row(left: pendingRemoved[i], right: nil, kind: .removed))
            }
            for i in pairs..<pendingAdded.count {
                rows.append(Row(left: nil, right: pendingAdded[i], kind: .added))
            }
            pendingRemoved.removeAll()
            pendingAdded.removeAll()
        }

        func flushHunk() {
            flushPairs()
            if let header {
                result.append(Hunk(header: header, rows: rows, added: added, removed: removed))
            }
            rows = []
            added = 0
            removed = 0
        }

        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                flushHunk()
                header = line
                continue
            }
            // Before any hunk header: git's preamble, dropped.
            guard header != nil else { continue }

            if line.hasPrefix("+") {
                pendingAdded.append(Line(kind: .added, text: String(line.dropFirst())))
                added += 1
            } else if line.hasPrefix("-") {
                pendingRemoved.append(Line(kind: .removed, text: String(line.dropFirst())))
                removed += 1
            } else if line.hasPrefix(" ") {
                // A context line ends any run of changes, so the runs above it
                // are paired before it is emitted. Without this, changes either
                // side of a context line would pair across it.
                flushPairs()
                rows.append(Row(left: Line(kind: .context, text: String(line.dropFirst())),
                                right: Line(kind: .context, text: String(line.dropFirst())),
                                kind: .context))
            } else if line.hasPrefix("\\") {
                // `\ No newline at end of file` belongs to the line above it;
                // it is not a row of its own.
                continue
            }
            // Anything else between hunks (a `diff --git` for the next file)
            // ends this hunk without a new header here; the next `@@` starts
            // the next one.
        }
        flushHunk()
        return result
    }

    /// Where two paired lines differ, as a half-open range of `Character`
    /// offsets into each side.
    ///
    /// Character offsets, not `utf8` or `unicodeScalars` offsets: a change
    /// inside a multi-scalar emoji — a flag, a family, an accent — must not
    /// split it, and the view slices the line by `Character` to tint the span.
    /// The two sides are separate ranges because an edit makes them different
    /// lengths: a pure insertion has nothing unique on the left, so its left
    /// range is empty, and the view tints nothing there.
    struct InlineDiff: Equatable {
        var left: Range<Int>
        var right: Range<Int>
    }

    /// The span that differs between a paired left and right line, found by
    /// trimming the common prefix and the common suffix.
    ///
    /// The pairing is a positional zip, not a real diff, so a pair of unrelated
    /// lines is expected. For those the prefix and suffix are both empty and the
    /// whole line is the span — which is the whole-line tint this replaced.
    /// Narrowing an unrelated pair to some accidental one-character "edit" would
    /// be worse than not narrowing at all, because it would read as a fact.
    ///
    /// The suffix trim is clamped to what the prefix left. Without that clamp,
    /// `"aaa"` against `"aaaa"` counts the same three `a`s as both prefix and
    /// suffix and reports spans past the end of the shorter line — a range that
    /// traps when the view slices with it.
    static func inlineDiff(left: String, right: String) -> InlineDiff {
        let l = Array(left), r = Array(right)
        let shorter = min(l.count, r.count)

        var prefix = 0
        while prefix < shorter, l[prefix] == r[prefix] { prefix += 1 }

        // At most what the prefix did not claim, so the two trims can never
        // describe the same character twice.
        let suffixLimit = shorter - prefix
        var suffix = 0
        while suffix < suffixLimit, l[l.count - 1 - suffix] == r[r.count - 1 - suffix] { suffix += 1 }

        return InlineDiff(left: prefix..<(l.count - suffix),
                          right: prefix..<(r.count - suffix))
    }

    /// Whether a diff has anything to lay out. An empty diff, or one made only
    /// of binary-file notices, draws nothing.
    static func hasContent(_ diff: String) -> Bool {
        hunks(in: diff).contains { !$0.rows.isEmpty }
    }
}