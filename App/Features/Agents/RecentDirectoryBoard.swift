import Foundation

/// Directories the host's agents have been working in, discovered from their
/// own on-disk history.
///
/// `enabled` is the `always-on-discovery` flag: false means the host was asked
/// not to go looking, which is different from having looked and found nothing,
/// and the screen says so rather than showing an empty list.
struct RecentDirectoryBoard: Codable {
    struct Entry: Codable, Identifiable, Equatable {
        var path: String
        /// Milliseconds since the epoch, from the newest transcript in that
        /// directory — when the agent was last active there.
        var at: Double
        /// Which agent's history this came from.
        var agent: String
        /// True when the path was reconstructed from a project's directory name
        /// rather than read from a record. The name is lossy — a dash inside a
        /// directory is indistinguishable from a separator — so a guess is
        /// shown as a guess.
        var inferred: Bool

        var id: String { path }

        var folderName: String {
            (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent
        }

        /// The directory above the folder, for a second line that tells two
        /// same-named checkouts apart.
        var parentPath: String {
            let parent = (path as NSString).deletingLastPathComponent
            return parent.isEmpty ? "/" : parent
        }

        var agentLabel: String {
            switch agent {
            case "claude": "Claude Code"
            case "codex": "Codex"
            case "cursor": "Cursor"
            case "opencode": "OpenCode"
            default: agent
            }
        }

        var agentSymbol: String {
            switch agent {
            case "claude": "sparkle"
            case "codex": "chevron.left.forwardslash.chevron.right"
            case "cursor": "cursorarrow"
            case "opencode": "terminal"
            default: "terminal"
            }
        }
    }

    var enabled: Bool = true
    var available: Bool = true
    var error: String?
    var directories: [Entry] = []
}
