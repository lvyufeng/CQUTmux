import Foundation

/// Whether the session a Chat View is reading has a turn in progress.
///
/// Moshi's Chat View: "A Working indicator follows the active turn", and its
/// close button "sends Escape to stop the current work when the session
/// supports it". Both halves read off one fact — is a turn active — so that
/// fact is derived here, once, rather than in the view, because getting it
/// wrong is quiet: a spinner that never clears, or one that clears while the
/// agent is still thinking, both look like the app simply disagreeing with the
/// agent.
///
/// The transcript is a log, not a state machine: it says what happened, not
/// whether the agent is busy now. So "busy" is read the same way the Inbox reads
/// a row's column — from the newest event for this session — and shares its
/// `ChatApproval` session matching so the two cannot disagree about *which*
/// session's events are being read.
enum ChatWorking {
    /// The category values that mean the turn is still live.
    ///
    /// `approvalRequired` is the agent blocked on the user, `toolRunning` is a
    /// tool mid-flight, and `toolFinished` is a tool that returned but whose
    /// result the agent has not yet finished with — all three are mid-turn.
    /// The turn is over on `task_complete` or `error`, and a `session_started`
    /// has not begun one: those three are *not* working.
    static let liveCategories: Set<AgentEvent.Category> = [
        .approvalRequired, .toolRunning, .toolFinished,
    ]

    /// The newest event for the session at `directory`, or nil when none of the
    /// events belong to it.
    static func newestEvent(in events: [AgentEvent], directory path: String) -> AgentEvent? {
        ChatApproval.forSession(in: events, directory: path).max { $0.id < $1.id }
    }

    /// Whether the session at `directory` has a turn in progress.
    static func isWorking(in events: [AgentEvent], directory path: String) -> Bool {
        guard let newest = newestEvent(in: events, directory: path) else { return false }
        return liveCategories.contains(newest.eventCategory)
    }
}