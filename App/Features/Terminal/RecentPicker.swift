import Foundation

/// What the session picker's Recent tab offers.
///
/// Three sources, kept apart on purpose: the session this app last attached to,
/// the folders the user browsed here, and the folders the host's own agents
/// worked in. The first two are the app's own history; the third is the host's
/// claim, read from the agents' logs. Merging them would make a folder the user
/// never opened look like one they had.
///
/// Decided here rather than in the view because the one distinction that
/// matters is invisible when it is wrong: a host asked not to look reports no
/// folders, and "we did not look" versus "there is nothing there" are the same
/// empty list on screen unless the two are told apart. Foundation-only, so the
/// checks can drive it.
enum RecentPicker {
    /// The sections the tab draws, in the order it draws them.
    enum Section: Equatable {
        /// The session last attached to on this host.
        case lastSession(LastSession)
        /// Folders this app recorded a visit to.
        case visited([String])
        /// Folders discovered from the host's agent logs.
        case agentFolders([RecentDirectoryBoard.Entry])
        /// The host was asked not to look. Not the same as finding nothing.
        case discoveryOff
    }

    /// The sections for one host, or an empty list when there is nothing to
    /// return to — which is what lets the view show a placeholder rather than an
    /// empty list that reads as broken.
    ///
    /// `discovered` is nil while the fetch is in flight or when it failed, and
    /// that is deliberately *not* `discoveryOff`: an unanswered question is not
    /// the answer "no".
    static func sections(
        last: LastSession?,
        visited: [String],
        discovered: RecentDirectoryBoard?
    ) -> [Section] {
        var sections: [Section] = []

        if let last {
            sections.append(.lastSession(last))
        }
        // A visited path is the app's own record, so it is shown whether or
        // not discovery is on — turning discovery off stops the host from
        // being read, not the app from remembering.
        if !visited.isEmpty {
            sections.append(.visited(visited))
        }

        if let discovered {
            if discovered.enabled {
                // Only when there is something: an "Agent history" header over
                // an empty list is a header that promises a section it does not
                // have, and it would appear on every host whose agents have no
                // usable logs.
                if !discovered.directories.isEmpty {
                    sections.append(.agentFolders(discovered.directories))
                }
            } else {
                sections.append(.discoveryOff)
            }
        }

        return sections
    }
}