import Foundation

// Whether the blame screen asks the right question, draws a row out of what
// git recorded, and words a refusal as itself.
//
// All three go wrong without an error appearing. `path` and `file` are
// opposite parameters, and a swapped pair is still a valid request: git is
// handed a path that is not there relative to the directory it runs in, and
// answers `no such path` — blaming the file for a mistake in the query. A row
// built from the raw fields shows an uncommitted line's all-zero hash as a
// commit and the moment of the blame as when the line was written. And every
// refusal arrives as "no lines", so a 403 drawn as a table reads as an empty
// file. `BlameModel.swift` is Foundation-only, so all three are asserted here
// without a simulator.

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

// A fixed clock and a fixed locale. A relative time taken against `Date()` and
// the machine's own locale is a check that passes where it was written and
// fails elsewhere: this machine's locale is zh_CN, where the same date reads
// "2年前".
let now = Date(timeIntervalSince1970: 1_640_995_200) // 2022-01-01T00:00:00Z
let en = Locale(identifier: "en_US")

let zeroHash = String(repeating: "0", count: 40)
let realHash = String(repeating: "a", count: 40)

func line(_ number: Int, hash: String = realHash, author: String = "Ada Lovelace",
          time: Double? = 1_577_836_800, // 2020-01-01T00:00:00Z
          content: String = "let value = 1", boundary: Bool = false,
          committed: Bool = true) -> BlameLine {
    BlameLine(line: number, hash: hash, author: author, email: "ada@example.com",
              time: time, summary: "a commit", filename: "main.swift",
              boundary: boundary, committed: committed, content: content, previous: nil)
}

func blame(_ lines: [BlameLine]) -> RevisionBlame {
    RevisionBlame(path: ".", rev: "", file: "main.swift", lines: lines)
}

func segments(_ caption: String) -> [String] {
    caption.components(separatedBy: " · ")
}

// MARK: - The request

// The working-tree viewer holds a path named from the gateway's root. The
// directory git must run in is its parent; the file is the name alone inside
// it.
let nested = BlameRequest.workingTree(file: "proj/src/main.swift")
check(nested.path == "proj/src", "a working-tree blame runs git in the file's directory")
check(nested.file == "main.swift", "and names the file as the path inside it")
check(nested.rev == "", "and no revision, which is what the working tree is")

// A file at the root of what the gateway serves has no parent at all. The root
// is spelled "." — the route's own spelling for it — rather than left empty,
// which the query builder drops as though the parameter had never been named.
let top = BlameRequest.workingTree(file: "main.swift")
check(top.path == ".", "a file at the root blames from \".\", not from an empty parent")
check(top.file == "main.swift", "with the name still the file")

let deep = BlameRequest.workingTree(file: "a/b/c/d.txt")
check(deep.path == "a/b/c" && deep.file == "d.txt", "a deeper path splits at the last slash")

// A blame at a commit is the other shape: the directory the browser is open at
// stays `path`, and the file is the path inside the commit's tree. Descending
// to the file's parent instead would run git in a directory that at a past
// commit may no longer exist — git refuses to start in one that is not there,
// while a path into the commit's own tree it resolves with no trouble.
let atCommit = BlameRequest.commit(rev: "abcdef1234", root: "proj", file: "src/main.swift")
check(atCommit.path == "proj", "a blame at a commit runs git where the browser is open")
check(atCommit.file == "src/main.swift", "with the file as the path inside that commit's tree")
check(atCommit.rev == "abcdef1234", "and the commit it is blaming at")
check(BlameRequest.commit(rev: "abcdef1234", root: "", file: "src/main.swift").path == ".",
      "an empty root is spelled \".\" the same way")

// MARK: - One row

let ordinary = BlameRow(line(1), relativeTo: now, locale: en)
check(ordinary.number == 1, "a row keeps the number git gave the line")
check(ordinary.content == "let value = 1", "and the line verbatim")
check(ordinary.author == "Ada Lovelace", "and the author")
check(ordinary.date == "2y ago", "and the time, relative to now")
check(ordinary.hash == "aaaaaaa", "and git's seven-character abbreviation, not the full id")
check(!ordinary.uncommitted, "a committed line is not marked uncommitted")
check(ordinary.attribution == "Ada Lovelace · 2y ago · aaaaaaa",
      "the caption reads who, when, which commit")

// The edge of the blamed history. `^` is what `git blame` itself prints, so
// the screen says "history stops here" in the notation the command uses.
let boundary = BlameRow(line(2, boundary: true), relativeTo: now, locale: en)
check(boundary.hash == "^aaaaaaa", "a boundary commit carries git blame's ^ prefix")
check(boundary.attribution == "Ada Lovelace · 2y ago · ^aaaaaaa",
      "and the caption shows the prefix, not a separate badge")

// git's record for a line that is not committed yet is made of placeholders:
// an all-zero hash, the author "Not Committed Yet", and the *moment of the
// blame* as the author time (git writes the current time, not zero). Each is a
// field with a value, and none of them is true.
let fresh = BlameRow(
    line(3, hash: zeroHash, author: "Not Committed Yet", time: now.timeIntervalSince1970,
         content: "just added", committed: false),
    relativeTo: now, locale: en)
check(fresh.hash.isEmpty, "an uncommitted line shows no hash rather than an all-zero one")
check(fresh.author.isEmpty && fresh.date.isEmpty, "nor git's placeholder author, nor its blamed-now time")
check(fresh.uncommitted, "the row says the line is uncommitted")
check(fresh.attribution == "Not committed yet", "and the caption says so instead of naming a commit")
check(fresh.content == "just added", "the line itself is still the line")

// A record git could not date — `time: null` on the wire. The date is a part
// that is not there, not one that failed, and the caption must not leave a gap
// where it would go.
let undated = BlameRow(line(4, time: nil), relativeTo: now, locale: en)
check(undated.date.isEmpty, "a line with no recorded time has no date")
check(segments(undated.attribution) == ["Ada Lovelace", "aaaaaaa"],
      "and the caption closes over it, with no empty segment left behind")

let anonymous = BlameRow(line(5, author: ""), relativeTo: now, locale: en)
check(segments(anonymous.attribution) == ["2y ago", "aaaaaaa"],
      "a record with no author drops it rather than leaving a dangling separator")

let bare = BlameRow(line(6, author: "", time: nil), relativeTo: now, locale: en)
check(bare.attribution == "aaaaaaa", "a record with neither author nor time is the commit alone")

check(BlameRow(line(7, content: "\t  if x {"), relativeTo: now, locale: en).content == "\t  if x {",
      "leading tabs and spaces are the line, not formatting")
check(BlameRow(line(8, content: ""), relativeTo: now, locale: en).content.isEmpty,
      "an empty line is empty, for the view to draw as a blank code line")

// MARK: - The table

// The gutter is sized from the numbers it will hold. A one-line file is where
// a hardcoded width shows: it pads a one-digit number to a guessed column, or
// runs a big file's number into its code when the guess is short.
let single = BlameRow.rows(of: blame([line(1)]), relativeTo: now, locale: en)
check(single.count == 1, "a one-line blame is one row")
check(BlameRow.numberWidth(of: single) == 1, "and its gutter is one digit wide")
check(BlameRow.numberWidth(of: []) == 1, "an empty table still asks for a column, not for zero")
check(BlameRow.numberWidth(of: BlameRow.rows(of: blame((1...100).map { line($0) }))) == 3,
      "a hundred lines need three digits")
check(BlameRow.numberWidth(of: BlameRow.rows(of: blame((1...1000).map { line($0) }))) == 4,
      "a thousand lines need four")

check(BlameRow.rows(of: blame([line(1), line(2), line(3)])).map(\.number) == [1, 2, 3],
      "one row per line, in git's order")

// A one-line file whose one line is uncommitted: the row must survive both the
// count and the flags, which is where an off-by-one on "the previous line"
// would take the whole table with it.
let singleFresh = BlameRow.rows(
    of: blame([line(1, hash: zeroHash, author: "Not Committed Yet", committed: false)]),
    relativeTo: now, locale: en)
check(singleFresh.count == 1 && singleFresh[0].uncommitted,
      "a one-line uncommitted file is still one row, not an empty table")

// MARK: - What the host sends

// The shape `parseBlame` writes: `time` is a number or null, `previous` is a
// hash or null, and an uncommitted record keeps its placeholder fields. The
// decode is checked because a key this type required and the host did not send
// would throw before a single row could be built.
let wire = """
{"path":".","rev":"","file":"main.swift","lines":[\
{"line":1,"hash":"\(realHash)","author":"Ada Lovelace","email":"ada@example.com","time":1577836800,"summary":"first","filename":"main.swift","boundary":true,"committed":true,"content":"let value = 1","previous":null},\
{"line":2,"hash":"\(zeroHash)","author":"Not Committed Yet","email":"not.committed.yet","time":null,"summary":"","filename":"main.swift","boundary":false,"committed":false,"content":"","previous":null}]}
"""
let decoded = try! JSONDecoder().decode(RevisionBlame.self, from: Data(wire.utf8))
let decodedRows = BlameRow.rows(of: decoded, relativeTo: now, locale: en)
check(decodedRows.count == 2, "a blame from the host decodes to one row per line")
check(decodedRows[0].hash == "^aaaaaaa" && decodedRows[0].author == "Ada Lovelace",
      "with the boundary flag and the author intact")
check(decodedRows[0].date == "2y ago", "and the author time turned into a date")
check(decodedRows[1].hash.isEmpty && decodedRows[1].attribution == "Not committed yet",
      "and the uncommitted line still shows no hash after decoding")
check(decodedRows[1].content.isEmpty, "an empty line's content survives the wire empty")

// MARK: - A refusal

func refused(_ status: Int, _ message: String?, rev: String = "") -> BlameFailure {
    BlameFailure.classify(status: status, message: message, rev: rev)
}

// 403 and 404 are deliberately different answers: the first is a request that
// never named a path inside the repository, the second git's own refusal of
// one that did. Collapsing them loses the only distinction between "this app
// asked wrong" and "the repository has no such file".
let outsidePath = refused(403, "file outside root")
check(outsidePath == .refused(message: "file outside root"), "a 403 stays a refusal")
check(outsidePath != refused(404, "file outside root"),
      "the same message at 403 and 404 is not the same answer")
check(outsidePath.detail == "file outside root", "the gateway's own words are what is shown")

let noRepo = refused(404, "fatal: not a git repository (or any of the parent directories): .git")
check(noRepo == .notARepository, "git's \"not a git repository\" is read as itself")
check(noRepo.title == "Not a git repository", "and headed the way the Changes tab already words it")

let tooBig = refused(404, "file too large")
check(tooBig == .tooLarge, "the size cap is read as the size cap")
check(tooBig.title == "Too large to blame", "and does not read as a missing file")

let gone = refused(404, "fatal: no such path 'src/gone.swift' in HEAD")
check(gone == .missingFile(message: "fatal: no such path 'src/gone.swift' in HEAD", rev: ""),
      "a path git cannot find is a missing file")
check(gone.title == "No such file", "worded for the working tree when no revision was named")
let goneAtRev = refused(404, "fatal: no such path 'src/gone.swift' in abcdef", rev: "abcdef")
check(goneAtRev.title == "Not in this commit", "and for the commit when one was")
check(gone.title != goneAtRev.title, "the same 404 reads differently because the question did")

let stale = refused(404, "fatal: bad revision 'deadbeef'", rev: "deadbeef")
check(stale == .missingRevision(message: "fatal: bad revision 'deadbeef'"), "an unknown revision is its own answer")
check(stale.title == "No such commit", "and not a missing file")

// Anything the app does not recognise keeps what the host said, under a
// heading that claims nothing: the module's "unsafe revision" is a 404 about
// the request, and wording it "no such file" would assert a cause the message
// never gave.
let unknown = refused(404, "unsafe revision")
check(unknown == .server(status: 404, message: "unsafe revision"),
      "an unrecognised 404 is not claimed as a missing file")
check(unknown.detail == "unsafe revision", "and the host's message survives it")
check(refused(500, "boom") == .server(status: 500, message: "boom"), "a 500 keeps its status and message")
check(refused(503, nil).detail == "The host gateway answered 503.", "a message-less answer still names the status")

let all: [BlameFailure] = [.connection, outsidePath, noRepo, tooBig, gone, stale]
check(Set(all.map(\.title)).count == all.count, "no two refusals share a headline, so none reads as another")
check(BlameFailure.connection.title != unknown.title, "a dropped connection does not read as the host's refusal")
check(all.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty }, "and every refusal has something to show")
check(all.allSatisfy { !$0.symbol.isEmpty }, "and a glyph to go with it")

if failures > 0 {
    print("\nBLAMEVIEW_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nBLAMEVIEW_PASS  (\(checks) checks)")