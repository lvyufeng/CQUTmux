import Foundation

// Laying a unified diff out side by side.
//
// The pairing is what cannot be eyeballed, and it fails silently both ways: pair
// too eagerly and an unrelated deletion and insertion read as one edit the agent
// never made, pair too rarely and every modification reads as a whole-line
// rewrite. So the rule runs here against real hunks rather than on a screen.

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("PASS  \(label)")
    } else {
        failures += 1
        print("FAIL  \(label)")
    }
}

// MARK: - A modification is one row, not two

let modify = """
diff --git a/app.py b/app.py
index 111..222 100644
--- a/app.py
+++ b/app.py
@@ -1,4 +1,4 @@
 import os
-print("old")
+print("new")
 def main():
     pass
"""
let modified = SideBySideDiff.hunks(in: modify)
check(modified.count == 1, "one hunk")
if let hunk = modified.first {
    check(hunk.header == "@@ -1,4 +1,4 @@", "the header is kept verbatim")
    // 3 context + 1 paired modification = 4 rows, not 5. The pairing is the
    // whole point: the removal and insertion are one row here, not two.
    check(hunk.rows.count == 4, "a modified line is one row, not two (got \(hunk.rows.count))")
    check(hunk.rows.contains { $0.kind == .modified }, "the row is marked modified")
    check(hunk.added == 1 && hunk.removed == 1, "the counts still count the lines, not the rows")

    let paired = hunk.rows.first { $0.kind == .modified }
    check(paired?.left?.text == "print(\"old\")", "the removed text is on the left")
    check(paired?.right?.text == "print(\"new\")", "the added text is on the right")
    check(paired?.left?.kind == .removed && paired?.right?.kind == .added,
          "and each side keeps its own kind")

    let context = hunk.rows.filter { $0.kind == .context }
    check(context.count == 3, "context lines are emitted once each")
    check(context.allSatisfy { $0.left?.text == $0.right?.text }, "a context row reads the same on both sides")
    // Only the diff's own one-space marker comes off; the line's indentation is
    // its content, so the indented body line keeps its four spaces.
    check(hunk.rows.first?.left?.text == "import os", "the leading space marker is stripped")
    check(hunk.rows.last?.left?.text == "    pass", "but the line's own indentation is kept")
}

// MARK: - Unpaired runs

// A pure insertion: nothing on the left. A naive implementation that always
// makes pairs would put these on the left and leave the right empty.
let insert = """
--- a/x
+++ b/x
@@ -1,1 +1,3 @@
 keep
+one
+two
"""
if let hunk = SideBySideDiff.hunks(in: insert).first {
    check(hunk.rows.count == 3, "two insertions are two rows (got \(hunk.rows.count))")
    check(hunk.rows.filter { $0.kind == .added }.count == 2, "insertions are marked added")
    check(hunk.rows.filter { $0.kind == .added }.allSatisfy { $0.left == nil },
          "an insertion has nothing on the left")
    check(hunk.rows.first { $0.kind == .added }?.right?.text == "one", "the inserted text is on the right")
}

let delete = """
--- a/x
+++ b/x
@@ -1,3 +1,1 @@
 keep
-gone
-also gone
"""
if let hunk = SideBySideDiff.hunks(in: delete).first {
    check(hunk.rows.filter { $0.kind == .removed }.count == 2, "deletions are marked removed")
    check(hunk.rows.filter { $0.kind == .removed }.allSatisfy { $0.right == nil },
          "a deletion has nothing on the right")
}

// MARK: - Pairing does not cross a context line

// The case that separates a real pairing rule from "pair everything in the
// hunk": the removal and the insertion are in the same hunk but on opposite
// sides of an unchanged line, so they are two changes, not one modification.
let separate = """
@@ -1,3 +1,3 @@
-only old
+only new
 unchanged
-other old
+other new
"""
let separated = SideBySideDiff.hunks(in: separate).first
check(separated?.rows.filter { $0.kind == .modified }.count == 2,
      "two modifications around a context line stay two (got \(separated?.rows.filter { $0.kind == .modified }.count ?? -1))")
check(separated?.rows.filter { $0.kind == .context }.count == 1, "the context line is one row")

// MARK: - Uneven runs

// Two removed, one added: one pair, then a leftover deletion. Pairing past the
// shorter run would read the extra deletion as a modification of nothing.
let uneven = """
@@ -1,3 +1,2 @@
 alpha
-beta
-gamma
+delta
"""
if let hunk = SideBySideDiff.hunks(in: uneven).first {
    check(hunk.rows.filter { $0.kind == .modified }.count == 1, "one pair from the shorter side")
    check(hunk.rows.filter { $0.kind == .removed }.count == 1, "the leftover deletion stays a deletion")
    let leftover = hunk.rows.first { $0.kind == .removed }
    check(leftover?.left?.text == "gamma" && leftover?.right == nil, "the leftover is the removed line")
    check(hunk.rows.first { $0.kind == .modified }?.left?.text == "beta",
          "the pair takes the first removed line, not the last")
}

// MARK: - Order within a hunk

// Rows come out in the order the diff reads: context, the change, context. A
// pairing pass that collects all pairs first would put the change at the end.
let ordered = """
@@ -1,3 +1,3 @@
 first
-old
+new
 last
"""
if let hunk = SideBySideDiff.hunks(in: ordered).first {
    check(hunk.rows.first?.kind == .context, "the first row is the leading context")
    check(hunk.rows.last?.kind == .context, "the last row is the trailing context")
    check(hunk.rows[1].kind == .modified, "the change sits between them")
}

// MARK: - Preamble and markers

// The `diff --git`/`index`/`---`/`+++` lines are git's metadata, not content.
// Laid out, `+++ b/file` beside `--- a/file` reads as the file having added and
// removed its own path.
check(SideBySideDiff.hunks(in: modify).first?.rows.contains { $0.left?.text.hasPrefix("++") == true } == false,
      "the file header is not laid out as content")
check(SideBySideDiff.hunks(in: "diff --git a/x b/x\nindex 1..2\n").isEmpty,
      "a diff with no hunk lays out nothing")

// `\ No newline at end of file` annotates the line above it; it is not a row.
let noNewline = """
@@ -1 +1 @@
-old
\\ No newline at end of file
+new
"""
if let hunk = SideBySideDiff.hunks(in: noNewline).first {
    check(hunk.rows.count == 1, "the no-newline marker is not a row (got \(hunk.rows.count))")
    check(hunk.rows.first?.kind == .modified, "and it does not break the pairing across it")
}

// MARK: - hasContent

check(!SideBySideDiff.hasContent(""), "an empty diff has no content")
check(SideBySideDiff.hasContent(modify), "a real diff has content")
check(!SideBySideDiff.hasContent("Binary files a/x and b/x differ\n"),
      "a binary-file notice is not content to lay out")

// MARK: - Multiple hunks

let twoHunks = """
@@ -1 +1 @@
-a
+b
@@ -10 +10 @@
-c
+d
"""
let both = SideBySideDiff.hunks(in: twoHunks)
check(both.count == 2, "two hunks are two hunks")
check(both.allSatisfy { $0.rows.count == 1 && $0.rows[0].kind == .modified },
      "and each pairs its own line")

// MARK: - Character spans inside a modified line

// A modified row used to tint both whole lines. The span narrows that to the
// characters that actually differ, so a one-word edit in a long line reads as a
// one-word edit rather than a rewrite. The model computes it on `Character` and
// the view tints the run this returns.

// Identical lines differ nowhere. A fallback that returned the whole line here
// would tint every context row.
let identical = SideBySideDiff.inlineDiff(left: "let x = 1", right: "let x = 1")
check(identical.left.isEmpty && identical.right.isEmpty, "identical text has no span on either side")

// A pure insertion: nothing is unique on the left, and the right span is
// exactly the inserted text. Widening either end by one would tint a character
// the two lines share.
let inserted = SideBySideDiff.inlineDiff(left: "abc", right: "abXc")
check(inserted.left.isEmpty, "an insertion leaves the left span empty")
check(inserted.right == 2..<3, "and the right span is the inserted character (got \(inserted.right))")

// A blank removed line paired with an added one is the same case in a real
// diff, and the side with no text must not produce a range past its own end.
let blank = SideBySideDiff.inlineDiff(left: "", right: "new")
check(blank.left.isEmpty && blank.right == 0..<3, "a blank line has no span, the other side has all of it")

// A pure deletion is the mirror image.
let deleted = SideBySideDiff.inlineDiff(left: "abXc", right: "abc")
check(deleted.left == 2..<3, "a deletion spans the removed character (got \(deleted.left))")
check(deleted.right.isEmpty, "and leaves the right span empty")

// A change in the middle: the changed word, not the shared head or tail.
let midChange = SideBySideDiff.inlineDiff(left: "hello world", right: "hello there")
check(midChange.left == 6..<11, "a middle change spans only the changed run on the left (got \(midChange.left))")
check(midChange.right == 6..<11, "and the matching run on the right (got \(midChange.right))")

// A change at the very start still trims the shared suffix, so the span is the
// first character rather than the whole line.
let atStart = SideBySideDiff.inlineDiff(left: "abc", right: "xbc")
check(atStart.left == 0..<1 && atStart.right == 0..<1, "a change at the start spans the first character")

// A change at the very end still trims the shared prefix.
let atEnd = SideBySideDiff.inlineDiff(left: "abc", right: "abx")
check(atEnd.left == 2..<3 && atEnd.right == 2..<3, "a change at the end spans the last character")

// The overlap case: prefix and suffix would both claim the same `a`s. The
// suffix trim is clamped to what the prefix left, so the span is the one extra
// character and never runs past the end of the shorter line.
let overlap = SideBySideDiff.inlineDiff(left: "aaa", right: "aaaa")
check(overlap.left.isEmpty, "overlapping prefix and suffix leave the shorter side unhighlighted")
check(overlap.right == 3..<4, "and the longer side's span is the one extra character (got \(overlap.right))")

// Characters are grapheme clusters, not scalars. This family emoji is three
// pictographs joined by two zero-width joiners — five scalars, one `Character`.
// It is spelled in escapes so the joiners cannot be dropped in passing: a
// literal that lost them is three pictographs, and a span counted in scalars
// would land inside the sequence and split it across two runs either way.
let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
check(family.count == 1, "the family emoji is one character despite being five scalars")
let emoji = SideBySideDiff.inlineDiff(left: family + " x", right: family + " y")
check(emoji.left == 2..<3 && emoji.right == 2..<3,
      "an emoji is one character, so the span is the character after it (got \(emoji.left))")

// Unrelated lines: the pairing is a positional zip, not a real diff, so this
// happens. The whole line is the span — the tint this replaced — and the span
// must not turn an accidental pair into a spurious one-character edit.
let unrelated = SideBySideDiff.inlineDiff(left: "totally different", right: "nothing alike")
check(unrelated.left == 0..<17 && unrelated.right == 0..<13,
      "unrelated lines keep the whole-line span, not an accidental narrow one")

// End to end: the paired row from a real hunk narrows to the word that changed.
if let hunk = SideBySideDiff.hunks(in: modify).first,
   let paired = hunk.rows.first(where: { $0.kind == .modified }) {
    let span = SideBySideDiff.inlineDiff(left: paired.left?.text ?? "", right: paired.right?.text ?? "")
    check(span.left == 7..<10 && span.right == 7..<10,
          "the real hunk's span is the quoted word, not the whole line (got \(span.left))")
}

if failures > 0 {
    print("\nSIDEBYSIDE_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nSIDEBYSIDE_PASS  (\(checks) checks)")
