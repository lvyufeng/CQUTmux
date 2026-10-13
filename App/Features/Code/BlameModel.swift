import Foundation

/// The blame screen's decisions, kept apart from the screen.
///
/// Three of them fail silently if a view works them out while drawing. The
/// query has two path parameters whose meanings are opposite, and a swapped
/// pair is still a request — it just asks about somewhere else, and the answer
/// blames the file for a bug in the query. Measured against the gateway:
/// handing `path` the file itself makes git unable to run at all, since the
/// directory it is given is a file, and the route fails with `spawn ENOTDIR` —
/// which reads as the host being broken, not as a malformed query. A row's attribution comes from fields that are
/// not all true: an uncommitted line arrives with an all-zero hash and a
/// plausible author and time, and drawing those shows a commit that does not
/// exist. And every way a blame can fail reaches the app as "no lines", so a
/// failure drawn as a list is an empty file.
///
/// Foundation-only so all three can be asserted by `swiftc` —
/// `scripts/blameview-check.sh` — without a simulator, the same split
/// `SideBySideDiff` and `RevisionPath` keep.

/// One blame request, in the three parts `/blame` takes.
///
/// `path` is the directory git is run *in*; `file` is the path inside it. Both
/// are named from the gateway's root here — the host resolves them relative to
/// the root it was started with — so only the split between them, not the
/// shape of the paths, differs between the two callers.
struct BlameRequest: Equatable {
    /// A directory that exists on the host.
    var path: String
    /// The commit to blame at, or "" for the working tree — the one place an
    /// absent value is the answer rather than a mistake.
    var rev: String
    /// The path inside `path`, not another location.
    var file: String

    /// The working tree, for a file opened from its own listing.
    ///
    /// The listing names files from the gateway's root, so the directory to run
    /// git in is the file's parent and the file is the name alone. A file at
    /// the root has no parent at all, so it is spelled "." — the route's own
    /// spelling for the root — rather than left empty, which the query builder
    /// drops as though the parameter had never been named.
    static func workingTree(file: String) -> BlameRequest {
        let parent = (file as NSString).deletingLastPathComponent
        return BlameRequest(path: parent.isEmpty ? "." : parent,
                            rev: "",
                            file: (file as NSString).lastPathComponent)
    }

    /// A file inside a commit's tree, from the commit browser.
    ///
    /// `root` stays the directory the browser was opened at rather than
    /// descending to the file's parent: at a past commit that parent can be a
    /// directory that no longer exists on the working tree, and git refuses to
    /// run in a directory that is not there — while a path *inside* the commit
    /// it resolves with no trouble, which is what makes a file deleted since
    /// still blamable.
    static func commit(rev: String, root: String, file: String) -> BlameRequest {
        BlameRequest(path: root.isEmpty ? "." : root, rev: rev, file: file)
    }
}

/// One line of a blame, with everything the screen shows about it decided.
struct BlameRow: Equatable {
    /// The line number git reported — the row's identity, since a blame answers
    /// about one snapshot.
    let number: Int
    /// The line itself, verbatim: indentation and all.
    let content: String
    /// Who last touched it, or "" when the record carried none.
    let author: String
    /// A relative time ("2y ago"), or "" when git dated nothing.
    let date: String
    /// The commit's short hash, "" when there is no commit to name.
    let hash: String
    /// The line is in the working tree and in no commit yet.
    let uncommitted: Bool

    /// The caption: who, when, which commit — or what the line is instead.
    ///
    /// Built by dropping the empty parts rather than by joining the fields as
    /// they are. A record with no author and a line git could not date are both
    /// real — `--line-porcelain` repeats its metadata per line, and a record it
    /// could not date comes back with a nil time — and an unconditional join
    /// shows them as "Ada ·  · a1b2c3d", which reads as a name and a date that
    /// failed to load rather than as fields that were never there.
    var attribution: String {
        // An uncommitted line's record is made up of placeholders: git writes
        // an all-zero hash, the author "Not Committed Yet" and the moment of
        // the blame as the time. The one true thing about the line is that no
        // commit owns it, so that is all the row says.
        if uncommitted { return "Not committed yet" }
        return [author, date, hash].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// One line as the row for it.
    ///
    /// `locale` is a parameter rather than taken from the environment so the
    /// check can pin it: a relative time is localized text, and expectations
    /// that change with the machine's locale pass wherever they were written
    /// and fail everywhere else.
    init(_ line: BlameLine, relativeTo now: Date = Date(), locale: Locale = .current) {
        number = line.line
        content = line.content
        uncommitted = !line.committed
        // Nothing on an uncommitted row names a commit: its hash is all zeros
        // — which is not an object id, since an object id cannot be all zeros —
        // and its author and time describe the blame, not the line.
        guard line.committed else {
            author = ""
            date = ""
            hash = ""
            return
        }
        author = line.author
        // A boundary commit is where the blamed history stops — the root, or a
        // commit whose parents were not walked — and `git blame` prints the
        // same "^" for it, so the screen says it in the notation the command
        // itself uses rather than inventing a badge.
        hash = line.boundary ? "^" + RevisionPath.short(line.hash) : RevisionPath.short(line.hash)
        guard let when = line.date else {
            date = ""
            return
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = locale
        date = formatter.localizedString(for: when, relativeTo: now)
    }

    /// A whole blame as rows.
    static func rows(of blame: RevisionBlame, relativeTo now: Date = Date(),
                     locale: Locale = .current) -> [BlameRow] {
        blame.lines.map { BlameRow($0, relativeTo: now, locale: locale) }
    }

    /// The width the line-number gutter needs, in digits.
    ///
    /// Taken from the largest number in the table, not from a constant: a
    /// three-digit gutter runs the ten-thousandth line's number into its code
    /// — which reads as code — and a five-digit one holds a one-line file's
    /// number a thumb's width from the line it numbers.
    static func numberWidth(of rows: [BlameRow]) -> Int {
        let largest = rows.map(\.number).max() ?? 1
        return String(largest).count
    }
}

/// Why a blame came back with no lines, in the words the screen shows.
///
/// Every one of these is an answer the host meant: 403 for a request that names
/// something that is not a path inside the repository, 404 for everything git
/// itself refused — carrying git's own message, which is the only thing that
/// tells "not a git repository" apart from "no such path" apart from a blame
/// over the size cap. Drawn as one "could not load" they throw away the
/// distinction the wire bothered to make; drawn as an empty table they read as
/// a file with no lines, which is the one thing they are not.
enum BlameFailure: Equatable {
    /// No answer, or an answer this version cannot read. Not the host's
    /// opinion about anything — the tunnel, most likely.
    case connection
    /// 403. The request named something the gateway will not read as a path
    /// inside the repository. A working-tree file whose *name* starts with `-`
    /// or `:` reaches this: that request names the file alone, and the gateway
    /// refuses a name git could read as an option — which git itself would not
    /// have, since the host passes `--`.
    case refused(message: String?)
    /// 404 whose message is git's "not a git repository": the file's directory
    /// is not under version control, so there is no history to attribute.
    case notARepository
    /// 404 "file too large": over the host's cap, refused whole rather than
    /// shown in part, so no line is ever attributed by a truncated run.
    case tooLarge
    /// 404 for a path git cannot find. `rev` is what was asked at, because the
    /// answer differs: a file missing from the working tree is not the same
    /// event as a file missing from a commit.
    case missingFile(message: String?, rev: String)
    /// 404 for a revision git does not know — a host whose history was
    /// rewritten after the commit was listed.
    case missingRevision(message: String?)
    /// Any other answer, status and message kept as they came.
    case server(status: Int, message: String?)

    /// The headline.
    var title: String {
        switch self {
        case .connection: return "No answer from the host"
        case .refused: return "Not a path in this repository"
        case .notARepository: return "Not a git repository"
        case .tooLarge: return "Too large to blame"
        case .missingFile(_, let rev): return rev.isEmpty ? "No such file" : "Not in this commit"
        case .missingRevision: return "No such commit"
        case .server: return "Can't read the blame"
        }
    }

    /// The sentence under it. Where git or the gateway said something specific,
    /// that text is what is shown: it names the path, the revision or the
    /// refusal, and a paraphrase would drop exactly the part a user needs.
    var detail: String {
        switch self {
        case .connection:
            return "The blame didn't come back — the host connection dropped, or the answer wasn't one this app could read."
        case .refused(let message):
            return message ?? "The request named something that is not a path inside the repository."
        case .notARepository:
            return "This file's directory isn't under version control, so there is no history to attribute."
        case .tooLarge:
            return "The blame is over the host's size limit. It is refused whole rather than shown in part, so no line is left attributed to the wrong commit."
        case .missingFile(let message, let rev):
            return message ?? (rev.isEmpty
                ? "The file is not in the working tree."
                : "The file is not in this commit's tree.")
        case .missingRevision(let message):
            return message ?? "The repository has no commit with that id."
        case .server(let status, let message):
            return message ?? "The host gateway answered \(status)."
        }
    }

    /// The glyph, beside the words so a failure is described in one place.
    var symbol: String {
        switch self {
        // The Changes and History tabs answer "not a repository" with this
        // branch, so a blame that is not one says the same thing in the same
        // picture.
        case .notARepository: return "arrow.triangle.branch"
        case .connection: return "wifi.exclamationmark"
        case .refused: return "hand.raised"
        case .tooLarge: return "doc.text.magnifyingglass"
        case .missingFile: return "doc.questionmark"
        case .missingRevision: return "clock.arrow.circlepath"
        case .server: return "exclamationmark.triangle"
        }
    }

    /// A non-200 answer as the failure it is.
    ///
    /// `rev` is threaded through so the wording knows which question was asked
    /// — the same 404 is "no such file" about the working tree and "not in this
    /// commit" about a revision, and a single wording for both is wrong in one
    /// of the two places it is shown.
    static func classify(status: Int, message: String?, rev: String) -> BlameFailure {
        switch status {
        case 403:
            return .refused(message: message)
        case 404:
            // git's own words: the route passes the module's error straight
            // through, so the message is the delimiter between the 404s.
            let text = message ?? ""
            if text.contains("file too large") { return .tooLarge }
            if text.contains("not a git repository") { return .notARepository }
            if text.contains("bad revision") || text.contains("unknown revision")
                || text.contains("ambiguous argument") {
                return .missingRevision(message: message)
            }
            if text.contains("no such path") || text.contains("does not exist")
                || text.contains("No such file or directory") {
                return .missingFile(message: message, rev: rev)
            }
            // A 404 this version does not recognise — the module's "unsafe
            // revision", or a message from a gateway that is ahead of the app.
            // Kept under a heading that claims nothing rather than folded into
            // "no such file", which would assert a cause never established.
            return .server(status: status, message: message)
        default:
            return .server(status: status, message: message)
        }
    }
}