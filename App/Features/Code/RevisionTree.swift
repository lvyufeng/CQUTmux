import Foundation

/// Browsing the repository as it was at a past commit.
///
/// The Changes tab reads the working tree; this reads the same repository at a
/// revision, which is what the History tab's commits open onto. The listing and
/// the file come from the host (`/tree`, `/blob`), so this type is the part that
/// is decided here: which directory a tap moves to, and what "up" means.
///
/// That navigation is where a wrong answer is invisible. A path built with a
/// trailing slash, or `./src` at the root, is a path git still resolves — so the
/// listing looks right — while the breadcrumb, the "up" button and the equality
/// the view uses to decide whether it has moved all compare unequal, and the
/// browser stops navigating without ever showing an error.
enum RevisionPath {
    /// The parent of a repo-relative directory, or nil at the root.
    ///
    /// nil rather than `"."` or `""`: the view uses the return value to decide
    /// whether to draw an "up" row, and a value that is *some* directory means
    /// the root offers a step up to itself.
    static func parent(of dir: String) -> String? {
        let trimmed = dir.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        guard let slash = trimmed.lastIndex(of: "/") else { return "" }
        return String(trimmed[trimmed.startIndex..<slash])
    }

    /// A child of a repo-relative directory.
    ///
    /// The root is the empty string, so joining there is the name alone — not
    /// `"./name"`, which is the form that renders correctly and compares wrong.
    static func child(_ name: String, of dir: String) -> String {
        let parent = dir.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if parent.isEmpty { return name }
        return "\(parent)/\(name)"
    }

    /// The breadcrumb trail to a directory, outermost first, each with the path
    /// that returns to it. The root is not one of them — it is the crumb the
    /// view draws unconditionally, and including it here would give two ways to
    /// name it that compare unequal.
    static func breadcrumbs(of dir: String) -> [(name: String, path: String)] {
        let parts = dir.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        var result: [(name: String, path: String)] = []
        var running = ""
        for part in parts {
            running = child(part, of: running)
            result.append((name: part, path: running))
        }
        return result
    }

    /// A commit's short hash for display. Git's own abbreviation is seven
    /// characters; a shorter hash (a fixture, an ancient object) is left alone
    /// rather than padded, because a padded hash is not a hash.
    static func short(_ hash: String) -> String {
        hash.count <= 7 ? hash : String(hash.prefix(7))
    }
}

/// One entry of a revision's tree, as the host reports it.
struct TreeEntry: Codable, Identifiable, Equatable {
    var name: String
    var dir: Bool
    var submodule: Bool
    var mode: String
    var object: String
    var id: String { name }

    /// A submodule is a directory to walk into conceptually but has no blobs
    /// here to list, so it is shown but not opened — opening it would list an
    /// empty directory and read as a folder the commit left empty.
    var openable: Bool { dir && !submodule }
}

/// The listing of one directory at a revision.
struct RevisionListing: Codable {
    var path: String
    var rev: String
    var dir: String
    var entries: [TreeEntry]
}

/// One file's content at a revision.
struct RevisionFile: Codable, Identifiable {
    var path: String
    var rev: String
    var file: String
    var size: Int
    var content: String
    var id: String { "\(rev):\(file)" }

    /// The same shape the working-tree viewer takes, so both open in one view.
    ///
    /// Built by the caller rather than here: `FileContents` lives beside the
    /// transport client, and referring to it would pull that module into this
    /// file — which is Foundation-only so its path rules can be checked without
    /// a simulator.
    func asContents() -> (path: String, size: Int, content: String) { (file, size, content) }
}

/// A commit being browsed.
struct BrowseTarget: Identifiable, Equatable {
    var rev: String
    var short: String
    var subject: String
    var id: String { rev }
}
