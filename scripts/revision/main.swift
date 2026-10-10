import Foundation

// Whether browsing a past commit navigates the way git's own paths do.
//
// Every rule here can be wrong without an error appearing. A path joined with a
// slash at the root (`"./src"`), a parent that returns `"."` instead of nil, a
// breadcrumb that starts with an empty name — each still *resolves* to a real
// directory, so the listing looks right while "up", the breadcrumb and the
// equality the view moves on all disagree. `RevisionTree.swift` is
// Foundation-only, so the rules run here without a simulator.

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

// MARK: - Parent

// The root has no parent. nil, not `"."` — a value that is *some* directory
// would make the root offer a step up into itself, which loops.
check(RevisionPath.parent(of: "") == nil, "the root has no parent")
check(RevisionPath.parent(of: "src") == "", "a top-level directory's parent is the root")
check(RevisionPath.parent(of: "src/lib") == "src", "a nested directory's parent is the one above")
check(RevisionPath.parent(of: "a/b/c") == "a/b", "and so on for the next level")

// Leading and trailing slashes are the shapes that produce a parent that looks
// right and is not — `/src/` has parent `` or `/src` depending on where the
// slash is trimmed from, and one of them is wrong.
check(RevisionPath.parent(of: "/src/") == "", "a wrapped path's parent is the root")
check(RevisionPath.parent(of: "/a/b/") == "a", "a wrapped nested path's parent is not wrapped")

// MARK: - Child

// Root is the empty string, so the join is the name alone. `"./src"` is the
// form that lists correctly and compares wrong.
check(RevisionPath.child("src", of: "") == "src", "a child of the root is the name alone")
check(RevisionPath.child("main.swift", of: "src") == "src/main.swift", "a child of a directory joins")
check(RevisionPath.child("lib", of: "src/io") == "src/io/lib", "a child of a nested directory joins")
check(RevisionPath.child("x", of: "/src/") == "src/x", "a child of a wrapped path is not wrapped")

// Round-trips: the two are inverses, and a pair that is not is exactly the
// "navigates there but cannot come back" bug.
let deep = "a/b/c"
check(RevisionPath.parent(of: RevisionPath.child("d", of: deep)) == deep,
      "child then parent returns to where it started")

// MARK: - Breadcrumbs

let crumbs = RevisionPath.breadcrumbs(of: "src/io/net")
check(crumbs.count == 3, "one crumb per path segment")
check(crumbs.map(\.name) == ["src", "io", "net"], "crumbs read outermost first")
check(crumbs.map(\.path) == ["src", "src/io", "src/io/net"],
      "each crumb carries the path back to it")
check(RevisionPath.breadcrumbs(of: "") .isEmpty, "the root has no crumbs of its own")
check(RevisionPath.breadcrumbs(of: "/src/").map(\.path) == ["src"],
      "a wrapped path's crumb is not wrapped")

// The last crumb is where the user is; if it disagreed with the directory the
// breadcrumb would highlight the wrong segment.
check(RevisionPath.breadcrumbs(of: deep).last?.path == deep, "the last crumb is the current directory")

// MARK: - Short hash

check(RevisionPath.short("abcdef1234567890") == "abcdef1", "a full hash is abbreviated to seven")
check(RevisionPath.short("abcdef1") == "abcdef1", "a seven-character hash is left alone")
check(RevisionPath.short("abc") == "abc", "a short hash is not padded to seven")
check(RevisionPath.short("") == "", "an empty hash stays empty")

// MARK: - Tree entries

let file = TreeEntry(name: "main.swift", dir: false, submodule: false, mode: "100644", object: "a")
let folder = TreeEntry(name: "src", dir: true, submodule: false, mode: "040000", object: "b")
let sub = TreeEntry(name: "vendor", dir: true, submodule: true, mode: "160000", object: "c")

check(!file.openable, "a file is not openable as a directory")
check(folder.openable, "a directory is openable")
// A submodule *is* a directory, but its contents are in another repository;
// listing it here returns nothing, which reads as an empty folder rather than
// as a boundary.
check(!sub.openable, "a submodule is not openable even though it is a directory")

// MARK: - The file a revision hands back

let blob = RevisionFile(path: "/repo", rev: "abcdef1", file: "src/main.swift", size: 5, content: "hi\n")
let contents = blob.asContents()
check(contents.path == "src/main.swift", "a revision file opens under its repo-relative path")
check(contents.content == "hi\n", "with the content the commit held")
check(contents.size == 5, "and the size the host reported")
// Two revisions of the same path have to be distinct ids, or the viewer keeps
// the first one open when the second is asked for.
check(RevisionFile(path: "/repo", rev: "aaaaaaaa", file: "f", size: 1, content: "a").id
        != RevisionFile(path: "/repo", rev: "bbbbbbbb", file: "f", size: 1, content: "b").id,
      "the same path at two revisions has two ids")

// MARK: - What the host returns decodes

let listing = """
{"path":"/repo","rev":"abcdef1","dir":"src","entries":[
 {"name":"io","dir":true,"submodule":false,"mode":"040000","object":"aa"},
 {"name":"main.swift","dir":false,"submodule":false,"mode":"100644","object":"bb"}]}
"""
let decoded = try! JSONDecoder().decode(RevisionListing.self, from: Data(listing.utf8))
check(decoded.dir == "src" && decoded.entries.count == 2, "a listing decodes")
check(decoded.entries[0].openable && !decoded.entries[1].openable,
      "and the directory/file distinction survives decoding")
// The root listing is the one with no `dir` key at all, which is what the host
// sends; a decode that required it would fail on the first request.
let root = """
{"path":"/repo","rev":"abcdef1","dir":"","entries":[]}
"""
check(try! JSONDecoder().decode(RevisionListing.self, from: Data(root.utf8)).entries.isEmpty,
      "an empty root listing decodes")

if failures > 0 {
    print("\nREVISION_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nREVISION_PASS  (\(checks) checks)")
