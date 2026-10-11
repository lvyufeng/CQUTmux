import Foundation

/// The pending approval that belongs to the session a Chat View is reading.
///
/// Moshi's Chat View shows a floating approval bar *in addition to* the Inbox —
/// "Permission requests can appear in a floating approval bar with Approve and
/// Deny", and the buttons "act on the live session". So this is a second surface
/// for one action, not a second action: it picks the event out of the same live
/// stream the Inbox reads, and the bar it feeds answers through the same
/// `HookClient.resolve` the Inbox uses.
///
/// Which event is "the live session's" is the only rule here, and it fails
/// quietly: the wrong pick shows another session's approval, and answering it
/// sends a decision the user did not mean. So the selection is a pure function
/// over the events, driven in `scripts/chat-approval-check.sh` rather than
/// looked at on a screen.
enum ChatApproval {
    /// The approval or question still waiting for the session at `directory`,
    /// or nil when there is nothing to show.
    ///
    /// The transcript is keyed by directory and an event carries the agent's
    /// `cwd`, so the directory is the join between what is on screen and what is
    /// pending. Newest first throughout, because a session can accumulate more
    /// than one pending event and the one the user is looking at is the latest —
    /// the same "newest wins" the board's rows use.
    static func pending(in events: [AgentEvent], directory path: String) -> AgentEvent? {
        let waiting = events.filter(\.isPending).sorted { $0.id > $1.id }
        guard !waiting.isEmpty else { return nil }

        if let matched = waiting.first(where: { matches($0, path: path) }) { return matched }

        // The chat can be opened with no directory at all: the Terminal falls
        // back to ".", the gateway's own working directory, and reads the
        // transcript from there. The session on screen is then whatever the
        // gateway resolved, and which pending approval is *theirs* cannot be
        // read off the events — the cwd they carry is absolute. So only a single
        // pending is shown, where there is nothing to choose wrongly; a second
        // one removes the bar rather than risk a decision on the wrong session.
        if isUnknown(path), waiting.count == 1 { return waiting[0] }
        return nil
    }

    /// Every event that belongs to the session at `directory`, newest first.
    ///
    /// The shared selection behind both the approval bar and the Working
    /// indicator: the two ask different questions of the same session, and if
    /// they disagreed about *which* events are that session's — the approval bar
    /// showing one session's request while the spinner reflected another's
    /// activity — the screen would contradict itself with nothing to show why.
    ///
    /// The chat can be opened with no directory at all: the Terminal falls back
    /// to ".", the gateway's own working directory, and reads the transcript
    /// from there. The session on screen is then whatever the gateway resolved,
    /// and which events are *theirs* cannot be read off the events — the cwd
    /// they carry is absolute. So with no directory every event is handed back
    /// (callers that need a single one, like the approval bar, further require
    /// there be exactly one, where there is nothing to choose wrongly).
    static func forSession(in events: [AgentEvent], directory path: String) -> [AgentEvent] {
        guard !isUnknown(path) else { return events }
        return events.filter { matches($0, path: path) }
    }

    /// Whether an event's working directory is the one a Chat View is reading.
    ///
    /// Exact match first, then the last path component. The chat's path can be
    /// relative — the Files browser walks down from "." — while the event's
    /// `cwd` is always absolute, so the component is the part the two share. It
    /// is the same reading the board groups projects by: a repository is named
    /// by its last component.
    private static func matches(_ event: AgentEvent, path: String) -> Bool {
        guard let cwd = event.data?.cwd, !cwd.isEmpty, !isUnknown(path) else { return false }
        if cwd == path { return true }
        return (cwd as NSString).lastPathComponent == (path as NSString).lastPathComponent
    }

    /// A path that names no directory an event could carry — the "." the chat
    /// opens with when no recent directory is known. An empty path is the same
    /// absence spelled differently.
    private static func isUnknown(_ path: String) -> Bool {
        path.isEmpty || path == "."
    }
}