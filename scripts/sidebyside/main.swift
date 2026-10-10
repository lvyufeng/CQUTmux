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

if failures > 0 {
    print("\nSIDEBYSIDE_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nSIDEBYSIDE_PASS  (\(checks) checks)")
