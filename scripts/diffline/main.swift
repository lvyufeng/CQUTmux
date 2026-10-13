import Foundation

// Classifying a unified diff's lines for the chat's diff sheet.
//
// The rule this replaced was a per-line prefix test with `+++`/`---`
// exemptions, and those exemptions are the tell: a file header and a hunk line
// whose content starts with `++`/`--` are spelled identically, so a prefix test
// can only ever get one of them right. These checks run the real classifier —
// the shipped file, compiled Foundation-only — against the shapes a host's
// `git diff --no-color` produces, including the ones a prefix test cannot.

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

func kinds(_ diff: String) -> [DiffLineKind] {
    DiffLineKind.lines(in: diff).map(\.kind)
}

func texts(_ diff: String) -> [String] {
    DiffLineKind.lines(in: diff).map(\.text)
}

// MARK: - A real diff

// Two text files, a new file and a binary one, as the host's git writes them.
// The second `@@` deliberately sits mid-output: a hunk header is a hunk header
// wherever it appears, and the header spellings reappear below as *content*.
let realText = """
diff --git a/app.py b/app.py
index 1111111..2222222 100644
--- a/app.py
+++ b/app.py
@@ -1,4 +1,5 @@
 import os
-print("old")
+print("new")
+print("extra")
 def main():
     pass
@@ -10,2 +11,2 @@
 context
--- a/file
+++ b/file
diff --git a/notes.md b/notes.md
new file mode 100644
index 0000000..3333333
--- /dev/null
+++ b/notes.md
@@ -0,0 +1,2 @@
+first
+second
diff --git a/icon.png b/icon.png
index aaa..bbb 100644
Binary files a/icon.png and b/icon.png differ
"""
let real = DiffLineKind.lines(in: realText)

check(real.count == 26, "every line is a line: none dropped, none invented (got \(real.count))")
// A multiline literal does not carry the newline before its closing delimiter,
// so the fixture has no trailing newline to drop; the drop itself is covered by
// the escaped fixtures below, which do end in one.
check(real.map(\.text).joined(separator: "\n") == realText,
      "the text comes back verbatim, markers and all")
// Indexed only once the count is right, so a dropped line fails as a FAIL
// rather than as a crash on the first index past the end.
if real.count == 26 {
    check(real[0].kind == .metadata, "`diff --git` is metadata")
    check(real[1].kind == .metadata, "`index` is metadata")
    check(real[2].kind == .metadata, "the `--- a/app.py` header is metadata, not a removed line")
    check(real[3].kind == .metadata, "the `+++ b/app.py` header is metadata, not an added line")
    check(real[4].kind == .hunkHeader, "the `@@` line is the hunk header")
    check(real[5].kind == .context, "a ` ` line is context")
    check(real[6].kind == .removed, "a `-` line is removed")
    check(real[7].kind == .added, "a `+` line is added")
    check(real[10].text == "     pass", "a context line keeps its own indentation behind the marker")
    check(real[11].kind == .hunkHeader,
          "a hunk header that is not the first line of the output is still a hunk header")
    check(real[13].kind == .removed && real[13].text == "--- a/file",
          "the header spelling inside a hunk is a removed line (got \(real[13].kind))")
    check(real[14].kind == .added && real[14].text == "+++ b/file",
          "and `+++ b/file` inside a hunk is an added line (got \(real[14].kind))")
    check(real[16].kind == .metadata, "`new file mode` is metadata")
    check(real[18].kind == .metadata, "`--- /dev/null` is metadata: a new file has no old side to remove from")
    check(real[19].kind == .metadata, "the second file's `+++` header is metadata too: `diff ` reopened the preamble")
    check(real[21].kind == .added, "the new file's `+` lines are added")
    check(real[25].kind == .metadata, "a binary-file notice is metadata")
}

// MARK: - Blank lines

// A blank context line is a single space, marker included. Kept as an escaped
// string rather than a literal block so no editor can trim the space out and
// silently turn this into the next case.
let blankContext = "@@ -1,2 +1,2 @@\n keep\n \n-old\n+new\n"
check(kinds(blankContext) == [.hunkHeader, .context, .context, .removed, .added],
      "a blank context line is a context line (got \(kinds(blankContext)))")
check(texts(blankContext)[2] == " ",
      "and the space that marks it is kept as its text (got \(texts(blankContext)[2].debugDescription))")

// The same line after something in the path trimmed trailing whitespace. It is
// not content the classifier can vouch for — but it must not close the hunk:
// the change after it is still that hunk's content.
let stripped = "@@ -1,2 +1,2 @@\n keep\n\n-old\n+new\n"
check(texts(stripped)[2] == "", "a line that lost its marker is kept, not dropped")
check(kinds(stripped)[2] == .metadata, "and it is not claimed as content")
check(Array(kinds(stripped).suffix(2)) == [.removed, .added], "and it does not close the hunk")

// A blank *added* line is the marker alone.
let blankAdded = "@@ -1,1 +1,2 @@\n keep\n+\n"
check(kinds(blankAdded) == [.hunkHeader, .context, .added], "a line added as blank is an added line")
check(texts(blankAdded)[2] == "+", "with the marker alone as its text")

// MARK: - `\ No newline at end of file`

// The marker annotates the line above it and appears mid-hunk — after the
// removed line, before the added one — so it must neither be read as content
// nor close the hunk.
let noNewline = """
@@ -1 +1 @@
-old
\\ No newline at end of file
+new
\\ No newline at end of file
"""
check(kinds(noNewline) == [.hunkHeader, .removed, .noNewline, .added, .noNewline],
      "the no-newline marker is its own kind and the hunk continues through it (got \(kinds(noNewline)))")

// MARK: - Content that starts with the marker character

// The first character decides the kind; everything after it is content, even
// when the content is what a header would say.
let plusContent = "@@ -1,2 +1,2 @@\n keep\n-+ old\n++ new\n"
check(kinds(plusContent) == [.hunkHeader, .context, .removed, .added],
      "a line whose content starts with `+`/`-` still takes its kind from the marker")
check(texts(plusContent)[3] == "++ new", "and the content's own `+` is kept in the text")

// MARK: - Diffs without git's preamble

// Plain `diff -u`, or a fragment starting at the file headers: no `diff ` line
// ever appears, and the `---`/`+++` are still metadata because no hunk has
// opened yet.
let plain = """
--- a/x
+++ b/x
@@ -1 +1 @@
-a
+b
"""
check(kinds(plain) == [.metadata, .metadata, .hunkHeader, .removed, .added],
      "the classifier does not need a `diff ` line to find the hunk")

// MARK: - Edges

check(DiffLineKind.lines(in: "").isEmpty, "an empty diff has no lines")

// A mode-only change has no hunks at all, and the diff's trailing newline is
// not a row of its own.
let headerOnly = "diff --git a/x b/x\nold mode 100644\nnew mode 100755\n"
check(kinds(headerOnly) == [.metadata, .metadata, .metadata],
      "a mode-only change is all preamble, and the trailing newline adds nothing (got \(kinds(headerOnly).count) lines)")

if failures > 0 {
    print("\nDIFFLINE_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nDIFFLINE_PASS  (\(checks) checks)")